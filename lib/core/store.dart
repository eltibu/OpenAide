/// Which build this is. The Google Play build is made with
/// --dart-define=OPENAIDE_STORE=play: Play updates it, so it has no in-app
/// updater, and it has its own package name.
const playBuild = String.fromEnvironment('OPENAIDE_STORE') == 'play';

/// This build's Android package name, for links back into the app.
const appPackage =
    playBuild ? 'com.eltibu.openaide' : 'com.nexus.nexus_assistant';
