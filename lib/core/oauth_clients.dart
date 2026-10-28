/// The app's own sign-in registrations, made once by the publisher (not
/// by each user). Client IDs are not secrets: they are built into the app.
/// Empty means not registered yet, so that sign-in stays hidden.
library;

/// GitHub OAuth App (Device Flow on), shared by Accounts and Copilot.
const githubClientId = String.fromEnvironment('NEXUS_GITHUB_CLIENT_ID');

/// Microsoft Entra app (personal and work accounts, public client).
const microsoftClientId = String.fromEnvironment('NEXUS_MICROSOFT_CLIENT_ID');

/// Google Cloud "Web application" client, which Android sign-in names as
/// its server client.
const googleWebClientId = String.fromEnvironment('NEXUS_GOOGLE_CLIENT_ID');

/// Where browser sign-ins come back to the app.
const oauthRedirect = 'com.nexus.nexus_assistant://auth';
