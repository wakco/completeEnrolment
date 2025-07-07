#!/bin/zsh -f

# Commands
# For anything outside /bin /usr/bin, /sbin, /usr/sbin

C_JAMF="/usr/local/bin/jamf"
C_INSTALL="/usr/local/Installomator/Installomator.sh"
C_DIALOG="/usr/local/bin/dialog"
C_MKUSER="/usr/local/bin/mkuser"
C_ENROLMENT="/usr/local/bin/completeEnrolment"

# Variables

DEFAULTS_NAME="completeEnrolment"
# If you change DEFAULTS_NAME, make sure the domain in the config profiles matches, or it won't work
DEFAULTS_PLIST="$DEFAULTS_NAME.plist"
LIB="/Library"
DEFAULTS_FILE="$LIB/Managed Preferences/$DEFAULTS_PLIST"
LOGIN_PLIST="$LIB/LaunchAgents/$DEFAULTS_PLIST"
STARTUP_PLIST="$LIB/LaunchDaemons/$DEFAULTS_PLIST"
SETTINGS_PLIST="$LIB/Preferences/$DEFAULTS_PLIST"
CLEANUP_FILES=( "$C_ENROLMENT" )
CLEANUP_FILES+=( "$LOGIN_PLIST" )
CLEANUP_FILES+=( "$STARTUP_PLIST" )
CLEANUP_FILES+=( "$DEFAULTS_PLIST" )
JAMF_URL="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url )"
JAMF_SERVER="$( echo "$JAMF_URL" | awk -F '(/|:)' '{ print $4 }' )"
if SELF_SERVICE="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null )" ; then
 SELF_SERVICE_URL="selfserviceplus:"
else
 SELF_SERVICE_URL="selfserviceapp:"
 SELF_SERVICE="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null )"
fi
CPU_ARCH="$( arch )"

# Whose logged in

# The who command method is used as it is the only one that reliably returns _mbsetupuser as used by
# Setup Assistant, confirming it as the only username logged into the console is the best way to
# identify an ADE/DEP Jamf PreStage Enrollment (after confirming the script was started by Jamf Pro
# with a / in $1).

if [ "$( who | grep console | wc -l )" -gt 1 ]; then
 WHO_LOGGED="$( who | grep -v mbsetupuser | grep -m1 console | cut -d " " -f 1 )"
else
 WHO_LOGGED="$( who | grep -m1 console | cut -d " " -f 1 )"
fi

# Log File

# This will Generate a number of log files based on the task and when they started.

LOG_FILE="$LIB/Logs/$DEFAULTS_NAME-$( if [ "$1" = "/" ]; then echo "Jamf-$WHO_LOGGED" ; else echo "Command-$1" ; fi )-$( date "+%Y-%m-%d %H-%M-%S %Z" ).log"

# Functions

logIt() {
 echo "$(date) - $@" 2>&1 | tee -a "$LOG_FILE"
}

runIt() {
 local report="$3"
 case $2 in
  log)
   logIt "Running $1"
  ;;
  track)
   report="$1"
  ;&
  custom)
   logIt "Running $report"
  ;;
 esac
 eval "$1" 2>&1 | tee -a "$LOG_FILE"
}

defaultRead() {
 defaults read "$DEFAULTS_FILE" "$1" 2>/dev/null
}

settingsPlist() {
 eval "defaults $1 '$SETTINGS_PLIST' '$2' '$3' '$4'" 2>/dev/null
}

readSaved() {
 settingsPlist read "$1" | base64 -d
}

myInstall() {
 local repeatattempts=5
 until [ -e "$1" ] || [ $repeatattempts -eq 0 ]; do
  case $2 in
   policy)
    runIt "$C_JAMF policy -event $3" track
   ;;
   install)
    runIt "$C_INSTALL $3 NOTIFY=silent $GITHUB_API" custom "$C_INSTALL $3 NOTIFY=silent"
   ;;
   *)
    logIt "Error: myInstall: \$2 must be either policy or install, soft failing this install attempt by touching the check file"
    touch "$1"
   ;;
  esac
  if [ ! -e "$1" ]; then
   sleep 5
   ((repeatattempts--))
  fi
 done
 if [ ! -e "$1" ]; then
  
 fi
}

track() {
 case $1 in
  bool|integer|string)
   if [ "$( jq -Mr ".$2 // empty" "$TRACKER_JSON" )" = "" ]; then
    eval "plutil -insert $2 -$1 '$3' '$TRACKER_JSON'"
   else
    eval "plutil -replace $2 -$1 '$3' '$TRACKER_JSON'"
   fi
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "$2: $3" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
  ;;
  new)
   eval "plutil -insert listitem -json '{\"title\":\"$2\"}' -append '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "listitem: add, title: $2" >> "$TRACKER_COMMAND"
   fi
   if [ "$TRACKER_ITEM" = "" ]; then
    track integer currentitem 0
    TRACKER_ITEM=0
   else
    ((TRACKER_ITEM++))
    track integer currentitem $TRACKER_ITEM
   fi
  ;;
  add)
   eval "plutil -insert listitem.$TRACKER_ITEM.$2 -string '$3' -append '$TRACKER_JSON'"
  ;|
  update)
   eval "plutil -replace listitem.$TRACKER_ITEM.$2 -string '$3' -append '$TRACKER_JSON'"
  ;|
  add|update)
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "listitem: index: $TRACKER_ITEM, $2: $3" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
  ;;
 esac
}

# Lets get started

caffeinate -dimsuw $$ &

until [ -e "$DEFAULTS_FILE" ]; do
 sleep 1
done

# Load common settings

DIALOG_ICON="${"$( defaultRead dialogIcon )":-"caution"}"
ADMIN_ICON="${"$( defaultRead adminPicture )":-"--no-picture"}"
if [ "$ADMIN_ICON" != "--no-picture" ]; then
 ADMIN_ICON="--picture $ADMIN_ICON"
fi
TRACKER_COMMAND="/tmp/completeEnrolment.DIALOG_COMMANDS.log"
TRACKER_JSON="/private/var/root/completeEnrolment.json"
TRACKER_RUNNING="/tmp/completeEnrolment.DIALOG.run"
if [ -e "$TRACKER_JSON" ]; then
 TRACKER_ITEM=$( jq -Mr '.currentitem' "$TRACKER_JSON" )
fi
touch "$TRACKER_COMMAND" "$TRACKER_JSON"
CLEANUP_FILES+=( "$TRACKER_JSON" )
TEMP_ADMIN="${"$( defaultRead tempAdmin )":-"setup_admin"}"

# And start processing

case $1 in
 /)
  # Install completeEnrolment
  logIt "Installing $C_ENROLMENT..."
  ditto "$0" "$C_ENROLMENT"
  
  # Load & save command line settings from Jamf Pro
  # $4, $5, $6, $7, $8, $9, $10, $11 ?
  if [ "$4" = "" ]; then
   GITHUBAPI=""
  else
   GITHUBAPI="GITHUBAPI=$( echo "$4" | base64 -d )"
   settingsPlist write github -string "$4"
  fi
  TEMP_NAME="${"$( defaultRead tempName )":-"Setup Admin"}"
  if [ "$5" = "" ]; then
   TEMP_PASS="setup"
  else
   TEMP_PASS="$( echo "$5" | base64 -d )"
  fi
  settingsPlist write temp -string "$( echo "$TEMP_PASS" | base64 )"
  if [ "$6" = "" ]; then
   LAPS_PASS="$TEMP_PASS"
  else
   LAPS_PASS="$( echo "$6" | base64 -d )"
  fi
  settingsPlist write laps -string "$( echo "$LAPS_PASS" | base64 )"
  if [ "$7" = "" ] || [ "$8" = "" ]; then
   logAndExit 4 "API details are required for access to the \$JAMF_ADMIN password, the following was supplied:\nAPI ID: $7\nAPI Secret: $8"
  else
   API_ID="$( echo "$7" | base64 -d )"
   settingsPlist write apiId -string "$7"
   API_SECRET="$( echo "$8" | base64 -d )"
   settingsPlist write apiSecret -string "$8"
  fi
  EMAIL_PASS="${9:-""}"
  settingsPlist write email -string "$9"


  # Initialise dialog setup file, our "tracker"
  # although plutil can create an empty json, it can't insert into it, incorrectly mistaking the
  # file to be in another format (OpenStep), so well just add the first item with an echo
  echo '{"title":"none"}' > "$TRACKER_JSON"
  plutil -insert listitem -array "$TRACKER_JSON"
  track string title "Welcome to ${"$( defaultRead corpName )":-"The Service Desk"}"
  track string message "Please wait while this computer is set up..."
  track string icon "$DIALOG_ICON"
  track string liststyle "compact"
  track boot button1disabled true
  track string button1text "none"
  track string commandfile "$TRACKER_COMMAND"
  track string position "bottom"
  
  
  # set time
  runIt "/usr/sbin/systemsetup -settimezone '"${"$( defaultRead systemTimeZone )":-"$( systemsetup -gettimezone | awk '{print $NF}' )"}"'"
  #"# this comment fixes an Xcode display bug
  sleep 5
  SYSTEM_TIME_SERVER="${"$( defaultRead systemTimeServer )":-"$( systemsetup -getnetworktimeserver | awk '{print $NF}' )"}"
  #"# this comment fixes an Xcode display bug
  runIt "/usr/sbin/systemsetup -setnetworktimeserver $SYSTEM_TIME_SERVER"
  sleep 5
  runIt "/usr/bin/sntp -Ss $SYSTEM_TIME_SERVER"
  sleep 1
  
  # Install Rosetta (just in case, and skip it for macOS 28+)
  if [ "$CPU_ARCH" = "arm64" ] && [ $(sw_vers -productVersion | cut -d '.' -f 1) -lt 28 ]; then
   logIt "Installing Rosetta on Apple Silicon..."
   runIt "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
  fi
  
  # Install initial file
  runIt "$C_JAMF policy -event \"${"$( defaultRead policyInitialFiles )":-"installInitialFiles"}\""
  
  # Install Installomator
  # This can be either the custom version from this repository, or the script that installs the
  # official version.
  myInstall "/usr/local/Installomator/Installomator.sh" policy "${"$( defaultRead policyInstallomator )":-"installInstallomator"}"
  
  # Install swiftDialog
  myInstall "/usr/local/bin/dialog" install dialog

  # start setting up dialog plist
  defaults write "$LOGIN_PLIST" Label "$DEFAULTS_NAME.loginwindow"
  defaults write "$LOGIN_PLIST" RunAtLoad -bool TRUE
  chmod ugo+r "$LOGIN_PLIST"

  # Executed by Jamf Pro
  # Load config profile settings and save them for later use in a more secure location, do the same
  # for supplied options such as passwords, only attempt to store them in the Keychain (such as
  # email, and API passwords). This is to allow for hopefully a more secure process, but limiting
  # the access to some of the information to say only during the first 24 hours (at least coming
  # from Jamf Pro that way).
  setopt extended_glob
  case $WHO_LOGGED in
   _mbsetupuser)
    # Get setup quickly and start atLoginWindow for initial step tracking followed by a restart.
    # This includes creating a temporary admin account with automatic login status to get the first
    # Secure Token, without which so many things will break.
    
    # Setup Login Window
    defaults write "$LOGIN_PLIST" LimitLoadToSessionType -array "LoginWindow"
    defaults write "$LOGIN_PLIST" ProgramArguments -array "$C_ENROLMENT" "startTrackerDialog" "-restart"
    
    # Make sure loginwindow is running
    while [ "$( pgrep -lu "root" "loginwindow" )" = "" ]; do
     sleep 1
    done

    # Start Dialog
    launchctl load -S LoginWindow "$LOGIN_PLIST"
    # add completesetup as automatic login without volume owner details
   ;|
   ^_mbsetupuser)
    # We will need the login details of a Volume Owner (an account with a Secure Token) to proceed,
    # so we'll ask for it, and in this instance, no need to restart, once the login details are
    # collected, start the dialog and just start processing (after setting the computer name).
    # add completesetup with volume owner details, without automatic login.
    "$C_DIALOG"
    
    #
    defaults write "$LOGIN_PLIST" ProgramArguments -array "$C_ENROLMENT" "startTrackerDialog"
    launchctl load "$LOGIN_PLIST"
   ;|
   *)
    # set computername
    runIt "$C_JAMF policy -event ${"$( defaultRead policyComputerName )":-"fixComputerName"}"
   ;|
   _mbsetupuser)
    # restart by sending quit message to dialog
    defaults write "$STARTUP_PLIST" Label "$DEFAULTS_NAME.startup"
    defaults write "$STARTUP_PLIST" RunAtLoad -bool TRUE
    defaults write "$STARTUP_PLIST" ProgramArguments -array "$C_ENROLMENT" "process"
    chmod ugo+r "$STARTUP_PLIST"
   ;;
   *)
    # trigger processing
    "$C_ENROLMENT" process
   ;;
  esac
  unsetopt extended_glob
 ;;
 *)
  # load saved settings
 ;|
 startTrackerDialog)
  # to open the event tracking dialog
  touch "$TRACKER_RUNNING"
  "$C_DIALOG" --loginwindow --jsonfile "$TRACKER_JSON"
  rm -f "$TRACKER_RUNNING"
  if [ "$2" = "-restart" ]; then
   defaults delete "$LOGIN_PLIST" LimitLoadToSessionType
   defaults write "$LOGIN_PLIST" ProgramArguments -array "$C_ENROLMENT" "startTrackerDialog"
   shutdown -r now
  fi
 ;;
 process)
  # finishing setting up admin accounts
  defaults write "$STARTUP_PLIST" ProgramArguments -array "$C_ENROLMENT" "cleanUp"
 ;;
 cleanUp)
  # A clean up routine
  logIt "Removing: $CLEANUP_FILES"
  rm -rf $CLEANUP_FILES
 ;;
 *)
  # how did this happen
 ;;
esac

