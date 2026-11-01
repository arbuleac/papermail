# OAuth setup

SuperSparrow signs in through the system browser and never sees your password. It needs OAuth client registrations that you own. Create them once and put them in:

`~/Library/Application Support/SuperSparrow/oauth-clients.json`

```json
{
  "google":    { "clientID": "….apps.googleusercontent.com", "clientSecret": "…" },
  "microsoft": { "clientID": "00000000-0000-0000-0000-000000000000", "tenant": "common" }
}
```

## Google (Gmail)

1. Google Cloud Console → create a project → APIs & Services → Enable **Gmail API**.
2. OAuth consent screen: External, add yourself as a test user. While the app is in "Testing", up to 100 test users can sign in and refresh tokens expire after seven days unless you publish; publishing Gmail restricted scopes requires Google's verification and a CASA assessment.
3. Credentials → Create credentials → OAuth client ID → **Desktop app**. Copy the client ID and client secret. Google treats desktop client secrets as non-confidential; keeping it in a local file is the documented practice.
4. Scopes requested: `https://www.googleapis.com/auth/gmail.modify`.

## Microsoft (Microsoft 365 and Outlook.com)

1. Microsoft Entra admin center → App registrations → New registration. Supported account types: "Accounts in any organizational directory and personal Microsoft accounts".
2. Authentication → Add a platform → **Mobile and desktop applications** → add `http://localhost` as a redirect URI. Enable "Allow public client flows".
3. API permissions → Microsoft Graph → Delegated: `Mail.ReadWrite`, `Mail.Send`, `User.Read`, `offline_access`.
4. Copy the Application (client) ID. No secret is needed.
5. Work or school tenants may require admin consent before you can sign in.

## Where tokens go

Access and refresh tokens are stored in the login Keychain under the service `SuperSparrow`. Removing an account deletes them.
