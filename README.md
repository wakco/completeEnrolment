# completeEnrolment
The next version of enrollmentComplete.

## completeEnrolment script
The main script.

## json files
These are to help with configuring the config profiles in Jamf Pro.

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
This is a variation of Installomator based on a version of a 10.9 beta, that doesn't contain the label's, and uses the GitHub API, enabling the use of a Github API key, to handle accessing/downloading installers and version information from Github. By not including the labels the script is a mere 2000~ lines, instead of the 11000+ lines with all the labels attached, and instead grabs the labels directly from Installomator's Github labels folder. While this does mean requiring a match to the label's filename (some labels can be referenced multiple ways). This version can also read from a file in /usr/local/Installomator/labels and expects it to be formatted as a standard Installomator label (as a means of overriding what might be online), allowing for a more robust way of doing valuesfromarguments where the code might be more complex.

