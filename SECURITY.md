# Security policy

Wisp records screens, microphones and system audio, and can read browser tabs. Please treat
anything that could expose those recordings, or let someone record or read without the user
knowing, as a security issue.

## Reporting a vulnerability

**Do not open a public issue, discussion or pull request for a vulnerability.**

Report it privately through GitHub Security Advisories: open the repository's **Security**
tab and choose **Report a vulnerability**
(<https://github.com/Incerto-inc/wisp-macos/security/advisories/new>). Only the maintainers
can see the report.

Please include:

- what an attacker can do, and what they need first (another app on the same Mac, a crafted
  web page, physical access, …);
- steps to reproduce, ideally with the smallest setup that shows it;
- the Wisp commit you tested, your macOS version and your Mac model.

We will confirm we received the report, work with you on a fix in the private advisory, and
credit you when it is published, unless you would rather not be named. Please give us a
reasonable time to release a fix before you talk about the issue publicly.

## Supported versions

Wisp has no releases yet. Fixes go to the `main` branch.

## Examples of what we want to hear about

- Another process starting, stopping or watching a recording, or reading recordings, without
  going through macOS's own permissions.
- Wisp sending anything off the Mac. It is designed to make no network requests.
- Browser tab titles or addresses being written to logs or files, or tabs in private and
  incognito windows being listed by a browser that reports them as private (Chrome-family
  browsers and Arc; Safari and Dia do not report it).
- `Scripts/package-app.sh` deleting or replacing something other than Wisp.
