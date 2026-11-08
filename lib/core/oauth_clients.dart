/// The app's own sign-in registrations, made once by the publisher (not
/// by each user). Client IDs are not secrets: they are built into the app.
/// Empty means not registered yet, so that sign-in stays hidden.
library;

/// GitHub OAuth App (Device Flow on), shared by Accounts and Copilot.
/// OpenAide's own app unless a build names another.
const githubClientId = _githubFromBuild == ''
    ? 'Ov23liaLSTPoberudhyC'
    : _githubFromBuild;
const _githubFromBuild = String.fromEnvironment('NEXUS_GITHUB_CLIENT_ID');

/// Microsoft Entra app (personal and work accounts, public client flows
/// on), used with a device code for Outlook mail.
/// OpenAide's own registration, unless a build names another; the build
/// passes an empty value when its variable isn't set.
const microsoftClientId = _microsoftFromBuild == ''
    ? 'c14faf7c-b57d-43cb-9688-01f1fbf3f13b'
    : _microsoftFromBuild;
const _microsoftFromBuild = String.fromEnvironment('NEXUS_MICROSOFT_CLIENT_ID');

/// Google Cloud "Desktop app" client, for Gmail. Sign-in comes back to a
/// listener on the phone (127.0.0.1).
/// OpenAide's own client unless a build names another.
const googleClientId = _googleFromBuild == ''
    ? '887606475907-3qt8l8v3tugub3hvgb61abujj6oivpun.apps.googleusercontent.com'
    : _googleFromBuild;
const _googleFromBuild = String.fromEnvironment('NEXUS_GOOGLE_CLIENT_ID');

/// That client's secret, from the NEXUS_GOOGLE_CLIENT_SECRET repo variable.
/// Google treats it as public for installed apps (it ships inside every
/// copy), but its token endpoint still wants it. Kept out of the source so
/// secret scanners don't flag it. Without it, Google sign-in stays hidden.
const googleClientSecret = String.fromEnvironment('NEXUS_GOOGLE_CLIENT_SECRET');

/// Where browser sign-ins come back to the app.
const oauthRedirect = 'com.nexus.nexus_assistant://auth';
