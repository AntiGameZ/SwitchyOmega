library switchy_background;

import 'dart:html';
import 'dart:json' as JSON;
import 'dart:async';
import 'package:web_ui/web_ui.dart';
import 'package:switchyomega/switchyomega.dart';
import 'package:switchyomega/browser/lib.dart';
import 'package:switchyomega/browser/message/lib.dart';
import 'package:switchyomega/communicator.dart';

Communicator safe = new Communicator(window.top);
Browser browser = new MessageBrowser(safe);

@observable SwitchyOptions options;
@observable Profile currentProfile;
@observable SwitchProfile tempProfile = null;

Future applyProfile(String name, {bool refresh: false, bool noConfig: false}) {
  currentProfile = options.getProfileByName(name);

  var possibleResults = [];
  if (currentProfile is InclusiveProfile) {
    possibleResults = options.profiles.validResultProfilesFor(currentProfile)
        .map((p) => p.name).toList();
  } else if (currentProfile is IncludableProfile) {
    possibleResults = options.profiles.where((p) => p is IncludableProfile)
        .map((p) => p.name).toList();
  }

  bool readonly = currentProfile is! SwitchProfile;
  var profile = currentProfile;
  if (tempProfile != null && currentProfile is IncludableProfile) {
    tempProfile.defaultProfileName = currentProfile.name;
    tempProfile.name = '$name (+temp rules)';
    tempProfile.color = currentProfile.color;
    profile = tempProfile;
    deliverChangesSync();
  }

  return browser.applyProfile(profile, possibleResults,
      readonly: readonly, profileName: name,
      refresh: refresh,
      noConfig: noConfig);
}

Profile resolveProfile(Profile p, String url) {
  var uri = Uri.parse(url);
  var date = new DateTime.now();
  while (p != null) {
    if (p is InclusiveProfile) {
      p = p.tracker.getProfileByName(
          (p as InclusiveProfile).choose(url, uri.host, uri.scheme, date));
    } else {
      return p;
    }
  }
}

const String directDetails = 'DIRECT';

String getProfileDetails(Profile p, String url) {
  var uri = Uri.parse(url);
  switch (p.profileType) {
    case 'FixedProfile':
      var proxy = (p as FixedProfile).getProxyFor(url, uri.host, uri.scheme);
      return proxy == null ? directDetails : proxy.toPacResult();
    case 'DirectProfile':
      return directDetails;
    case 'PacProfile':
    case 'AutoDetectProfile':
      var url = (p as PacProfile).pacUrl;
      if (url != null && url.isNotEmpty) {
        return 'PAC Script: ' + url;
      }
      return 'PAC Script';
    default:
      return '(${p.profileType})';
  }
}

/**
 * Returns the names of profiles that fails to update.
 */
Future<Set<String>> updateProfiles() {
  var completer = new Completer<Set<String>>();
  var count = 0;
  var fail = new Set<String>();
  options.profiles.forEach((profile) {
    if (profile is UpdatingProfile) {
      if (profile.updateUrl == null || profile.updateUrl.isEmpty) return;
      if (profile is AutoDetectProfile &&
          options.profiles.referredBy(profile).isEmpty) return;
      count++;
      browser.download(profile.updateUrl).then((data) {
        profile.applyUpdate(data);
      }).catchError((e) {
        fail.add(profile.name);
      }).whenComplete(() {
        count--;
        if (count == 0) {
          completer.complete(fail);
        }
      });
    }
  });

  if (count == 0) completer.complete(fail);

  return completer.future;
}

Profile getStartupProfile(String lastProfileName) {
  var startup = null;
  if (options.startupProfileName.isNotEmpty) {
    startup = options.startupProfileName;
  } else if (lastProfileName != null) {
    startup = lastProfileName;
  }
  if (startup == null || options.profiles[startup] == null) {
    startup = new DirectProfile().name;
  }
  return options.profiles[startup];
}

void listenForProxyChange() {
  browser.onProxyChange.listen((e) {
    if (options.revertProxyChanges) {
      applyProfile(currentProfile.name);
      return;
    }
    var profile = e.toProfile(options.profiles);
    if (profile.name == '') {
      currentProfile = profile;
      browser.applyProfile(profile, [],
          readonly: true, profileName: '',
          noConfig: true);

      safe.send('state.set', {
        'type': 'info',
        'reason': 'externalProxy',
        'badge': '?'
      });
    } else {
      applyProfile(profile.name, noConfig: true);
    }
  });
}

const String initialOptions = '''
    {"enableQuickSwitch":false,"profiles":[{"bypassList":[{"pattern":"<local>",
    "conditionType":"BypassCondition"}],"profileType":"FixedProfile","name":
    "proxy","color":"#99ccee","fallbackProxy":{"port":8080,"scheme":"http",
    "host":"proxy.example.com"}},{"profileType":"SwitchProfile","rules":[{
    "condition":{"pattern":"internal.example.com","conditionType":
    "HostWildcardCondition"},"profileName":"direct"},{"condition":{"pattern":
    "*.example.com","conditionType":"HostWildcardCondition"},"profileName":
    "proxy"}],"name":"auto switch","color":"#99dd99","defaultProfileName":
    "direct"}],"refreshOnProfileChange":true,"startupProfileName":"",
    "quickSwitchProfiles":[],"revertProxyChanges":false,"schemaVersion":0,
    "confirmDeletion":true,"downloadInterval":1440}''';

void main() {
  safe.send('options.get', null, (Map<String, Object> o, [Function respond]) {
    if (o['options'] == null) {
      if (o['oldOptions'] != null) {
        options = upgradeOptions(o['oldOptions']);
      }
      if (options == null) {
        options = new SwitchyOptions.fromPlain(JSON.parse(initialOptions));
      }
      safe.send('options.set', JSON.stringify(options));
    } else {
      var version =
          (o['options'] as Map<String, String>)['schemaVersion'] as int;
      if (version < SwitchyOptions.schemaVersion) {
        options = upgradeOptions(o['options']);
        safe.send('options.set', JSON.stringify(options));
      } else if (version > SwitchyOptions.schemaVersion) {
        safe.send('state.set', {
          'type': 'error',
          'reason': 'schemaVersion',
          'badge': 'X'
        });
        return;
      } else {
        try {
          options = new SwitchyOptions.fromPlain(o['options']);
        } catch (e) {
          safe.send('state.set', {
            'type': 'error',
            'reason': 'options',
            'badge': 'X'
          });
          return;
        }
      }
    }
    browser.setAlarm('download', options.downloadInterval).listen((_) {
      updateProfiles();
    });

    safe.send('background.init');

    var startup = getStartupProfile(o['currentProfileName']);
    applyProfile(startup.name).then((_) {
      updateProfiles().then((fail) {
        if (fail.any((name) => name == startup.name || (
            startup is InclusiveProfile &&
            options.profiles.hasReferenceToName(startup, name)))) {
          safe.send('state.set', {
            'type': 'warning',
            'reason': 'download',
            'badge': '!'
          });
          listenForProxyChange();
        } else {
          applyProfile(startup.name).then((_) {
            listenForProxyChange();
          });
          safe.send('options.set', JSON.stringify(options));
        }
      });
    });
  });

  safe.on({
    'options.update': (plain, [_]) {
      options = new SwitchyOptions.fromPlain(plain);
      if (tempProfile != null) {
        for (var i = 0; i < tempProfile.length; ) {
          if (options.profiles[tempProfile[i].profileName] == null) {
            tempProfile.removeAt(i);
          } else {
            i++;
          }
        }
        deliverChangesSync();
      }
      if (options.profiles[currentProfile.name] == null) {
        applyProfile(getStartupProfile(null).name);
      } else {
        applyProfile(currentProfile.name);
      }
    },
    'options.reset': (_, [respond]) {
      options = new SwitchyOptions.fromPlain(JSON.parse(initialOptions));
      respond(initialOptions);
      applyProfile(getStartupProfile(null).name);
    },
    'profile.apply': (name, [_]) {
      applyProfile(name, refresh: options.refreshOnProfileChange);
    },
    'condition.add': (Map<String, String> data, [_]) {
      var profile = options.getProfileByName(data['profile']);
      if (profile is SwitchProfile) {
        var plainCondition = {
                              'conditionType': data['type'],
                              'pattern': data['details']
        };
        profile.insert(0, new Rule(new Condition.fromPlain(plainCondition),
            data['result']));
        deliverChangesSync();
        safe.send('options.set', JSON.stringify(options));
        if (profile.name == currentProfile.name || (
            currentProfile is InclusiveProfile &&
            options.profiles.hasReference(currentProfile, profile))) {
          applyProfile(currentProfile.name,
              refresh: options.refreshOnProfileChange);
        }
      }
    },
    'tempRules.add': (details, [_]) {
      if (options.profiles.getProfileByName(details['name']) == null) return;
      if (tempProfile == null) {
        tempProfile = new SwitchProfile('', new DirectProfile().name);
        tempProfile.tracker = new TempProfileTracker(options.profiles);
      }
      var condition = new HostWildcardCondition('*.' + details['domain']);
      tempProfile.insert(0, new Rule(condition, details['name']));
      deliverChangesSync();
      applyProfile(currentProfile.name,
                   refresh: options.refreshOnProfileChange);
    },
    'externalProfile.add': (name,  [_]) {
      if (currentProfile.name == '') {
        currentProfile.name = name;
        options.profiles.add(currentProfile);
        deliverChangesSync();
        safe.send('options.set', JSON.stringify(options));
        applyProfile(currentProfile.name,
            refresh: options.refreshOnProfileChange);
      }
    },
    'profile.match': (url, [respond]) {
      var profile = currentProfile;
      if (tempProfile != null) {
        profile = tempProfile;
      }
      if (profile is InclusiveProfile) {
        var result = resolveProfile(profile, url);
        var color = result.color;
        var details = getProfileDetails(result, url);
        if (details == directDetails) color = ProfileColors.direct;
        respond({
          'name': result.name,
          'color': color,
          'details': details
        });
      }
    }
  });
}
