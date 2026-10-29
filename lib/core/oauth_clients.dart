/// The app's own sign-in registrations, made once by the publisher (not
/// by each user). Client IDs are not secrets: they are built into the app.
/// Empty means not registered yet, so that sign-in stays hidden.
library;

/// GitHub OAuth App (Device Flow on), shared by Accounts and Copilot.
const githubClientId = String.fromEnvironment('NEXUS_GITHUB_CLIENT_ID');

/// Microsoft Entra app (personal and work accounts, public client flows
/// on), used with a device code for Outlook mail.
const microsoftClientId = String.fromEnvironment('NEXUS_MICROSOFT_CLIENT_ID');

/// Google Cloud "Desktop app" client, for Gmail. Sign-in comes back to a
/// listener on the phone (127.0.0.1).
const googleClientId = String.fromEnvironment('NEXUS_GOOGLE_CLIENT_ID');

/// That client's secret. Google treats it as public for installed apps
/// (it ships inside every copy), but its token endpoint still wants it.
const googleClientSecret = String.fromEnvironment('NEXUS_GOOGLE_CLIENT_SECRET');

/// Where browser sign-ins come back to the app.
const oauthRedirect = 'com.nexus.nexus_assistant://auth';
