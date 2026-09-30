# completeEnrolment
This is my version of an initial setup script, design for use with Jamf Pro.

## completeEnrolment script
The main script.
This script relies on the following tools for completing it's tasks, will install where necessary, and leaves them installed, for potential future use (without any login/api credentials):
- [swiftDialog](https://github.com/swiftDialog/swiftDialog) for displaying dialogs.
- [mkuser](https://github.com/freegeek-pdx/mkuser) for creating admin accounts.
- [jamf-cli](https://github.com/Jamf-Concepts/jamf-cli) for talking back to Jamf Pro via the API.
- [Installomator](https://github.com/Installomator/Installomator), assuming it is provided with a means to, this allows managing the version, i.e. the customised version provided in this repository, the original, or a personally customised version.

## json files
These Jamf Pro schema's are to help with configuring the config profiles.

### completeEnrolment.json
The main settings (and optional task list, or first task list)

### taskList.json
For additional tasks list that can be dynamically scoped in.

## Preset Tasks Lists
These are working example Task lists.

### Adobe
Includes the information required to track the installation of the entire Adobe Creative Cloud suite, as Jamf App Installers.

### Apple
Includes the information required to track the installation of Garageband, iMovie, Keynote, Numbers, and Pages from the Mac App Store, as Installed Automatically.

### Microsoft
Includes the information required to track the installation of the full Microsoft Office 365 suite, as well as Defender, Company Portal, and Edge, as Jamf App Installers, with Installomator.sh as a backup.

## Why is [Installomator.sh](https://github.com/Installomator/Installomator) here?
This is a variation of Installomator based on a version of a 10.9 beta, that doesn't contain the label's, and uses the GitHub API, enabling the use of a Github API key, to handle accessing/downloading installers and version information from Github. By not including the labels, the script is a mere 2000~ lines (instead of the 11000+ lines with all the labels attached) and grabs the labels directly from Installomator's Github labels folder at execution time. While this does mean requiring a match to the label's filename (some labels can be normally referenced with multiple names), getting the label at execution time means gettings the latest version of the label each time. This version can also read from a file in '/usr/local/Installomator/labels' and expects it to be formatted as a standard Installomator label (as a means of overriding what might be online), allowing for a more robust way of doing valuesfromarguments where the code might be more complex.

## Jamf Policy/Script $4-11 Variables

- $4 - Github API Key for Installomator (encoded with base64)
- $5 - Temporary (default) password (encoded with base64)
- $6 - LAPS first password (if empty, will use the temporary password, encoded with base64)
- $7 - Jamf API ID (or Jamf Platform API Gateway ID, encoded with base64)
- $8 - Jamf API Secret (or Jamf Platform API Gateway Secret, encoded with base64)
- $9 - Email password (encoded with base64)
- $10 - Jamf Platform API Gateway Environment ID (encoded with base64, required when using the Jamf Platform API Gateway)
- $11 - Jamf Platform API Gateway region code (apac - Asia Pacific, eu - Europe, us - United States, required when using the Jamf Platform API Gateway)

Note: All except $11 are base64 encoded, and are only decoded when used. While this is nothing more than obscuring the details, they are only stored on the computer until the script is finished. 


