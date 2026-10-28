# Security

## Reporting a problem

Please report security problems privately, not in a public issue: use
**Security > Report a vulnerability** on this repository's GitHub page.
You'll get an answer within a week. Please give us a reasonable time to fix
it before you talk about it publicly.

## How OpenAide keeps your data safe

- **Sign-ins, API keys, email passwords and OAuth tokens** are kept in
  Android's encrypted storage (Keystore), on your phone only. They are left
  out of Google's cloud backup and of transfers to a new phone.
- **No tracking.** The app has no analytics, ads or crash reporting. It
  talks only to the servers and services you set up (see
  [PRIVACY.md](PRIVACY.md)).
- **Phone actions** the assistant takes for you that reach other people
  (calls and texts) are only *prepared*: you press call or send yourself.
- **Reading web pages**: the assistant reads only public addresses, never
  pages on your phone or home network, so a web page can't make it look
  around your network.
- **Updates** come from this repository's GitHub releases over HTTPS, and
  Android installs one only if it carries the same signature as the app
  already on your phone.
- **Builds** run only for branches of this repository, never for pull
  requests from forks.

## Plain HTTP

Open WebUI servers at home are often reached as `http://192.168.x.x`, so
the app accepts plain HTTP on the home network (private addresses,
`localhost`, names like `nas` or `server.local`). For a server on the
internet it signs in over HTTPS only, unless you tap *Connect anyway* after
a warning: over plain HTTP your password and chats can be read by anyone on
the way.
