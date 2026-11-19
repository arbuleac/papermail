# OAuth setup

SuperSparrow signs in through the system browser and never sees your password. It needs OAuth client registrations that you own. Create them once (steps below), then enter them in the app:

**SuperSparrow → Settings… (⌘,) → OAuth**: paste the Google client ID and secret and/or the Microsoft client ID and tenant, and click **Save**. If you click "Add Gmail account" or "Add Microsoft account" before a client is configured, the app opens this tab for you. No relaunch is needed.

The tab writes `~/Library/Application Support/SuperSparrow/oauth-clients.json` (readable only by you, mode 0600). You can also edit that file by hand:

```json
{
  "google":    { "clientID": "….apps.googleusercontent.com", "clientSecret": "…" },
  "microsoft": { "clientID": "00000000-0000-0000-0000-000000000000", "tenant": "common" }
}
```

## Google (Gmail)

1. Google Cloud Console → create a project → APIs & Services → Enable **Gmail API**, and enable **Google Calendar API** too. It is what lets an answer to an invitation mark the event in your Google Calendar, and it is where the day column and the week read your events: until it is enabled, a Google account shows no events there, and the foot of the column reads "Turn on the Google Calendar API for" the account's name, with **How to turn it on**, which opens this step.
2. OAuth consent screen: External, add yourself as a test user. Under **Data access** (or **Scopes**), add `https://www.googleapis.com/auth/gmail.modify` and `https://www.googleapis.com/auth/calendar.events`. While the app is in "Testing", up to 100 test users can sign in and refresh tokens expire after seven days unless you publish; publishing Gmail restricted scopes requires Google's verification and a CASA assessment.
3. Credentials → Create credentials → OAuth client ID → **Desktop app**. Copy the client ID and client secret. Google treats desktop client secrets as non-confidential; keeping it in a local file is the documented practice.
4. Scopes requested: `https://www.googleapis.com/auth/gmail.modify` when you add the account. `https://www.googleapis.com/auth/calendar.events` is asked for later, the first time you answer an invitation (SuperSparrow then asks you to reconnect) or when you click **Connect** under "Show events from your calendars" at the foot of the day column; either way your browser shows Google's consent for the calendar. Every later sign-in keeps it. The one scope covers answering, reading your main calendar for the day column and the week, and adding or removing the time you set aside for a mail.

Without the Calendar API enabled, answers still reach the organizer by mail, but the event in your Google Calendar keeps showing "needs action", and the day column and the week show none of that account's events.

## Microsoft (Microsoft 365 and Outlook.com)

1. Microsoft Entra admin center → App registrations → New registration. Supported account types: "Accounts in any organizational directory and personal Microsoft accounts". SuperSparrow asks "Work or School" or "Personal" when you add a Microsoft account and signs that account in through `organizations` or `consumers` only, because one address can be both and Microsoft would otherwise pick for you; a registration limited to one kind only lets that kind sign in.
2. Authentication → Add a platform → **Mobile and desktop applications** → add `http://localhost` as a redirect URI, exactly that, with no port and no path (SuperSparrow redirects to `http://localhost:<random port>`, and Entra ignores the port of a loopback URI but compares the path). Enable "Allow public client flows".
3. API permissions → Microsoft Graph → Delegated: `Mail.ReadWrite`, `Mail.Send`, `User.Read`, `offline_access`, and `Calendars.ReadWrite` (to answer invitations, and for the day column and the week: reading your default calendar and adding or removing the time you set aside for a mail). SuperSparrow asks for `Calendars.ReadWrite` later, the first time you answer an invitation (by asking you to reconnect) or when you click **Connect** at the foot of the day column.
4. Copy the Application (client) ID. No secret is needed.
5. Work or school tenants may require admin consent before you can sign in, and again before the calendar permission can be granted.

## Where tokens go

Access and refresh tokens are stored in the login Keychain under the service `SuperSparrow`. Removing an account deletes them.
