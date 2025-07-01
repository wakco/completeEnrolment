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
DEFAULTS_PLIST="$DEFAULTS_NAME.plist"
LIB="/Library"
DEFAULTS_FILE="$LIB/Managed Preferences/$DEFAULTS_PLIST"
LOGIN_PLIST="$LIB/LaunchAgents/$DEFAULTS_PLIST"
STARTUP_PLIST="$LIB/LaunchDaemons/$DEFAULTS_PLIST"

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

LOG_FILE="$LIB/Logs/$DEFAULTS_NAME-$( if [ "$1" = "/" ]; then echo "$WHO_LOGGED" ; else echo "$1" ; fi )-$( date "+%Y-%m-%d %H-%M-%S %Z" ).log"

# Functions

logIt() {
 echo "$(date) - $@" 2>&1 | tee -a "$LOG_FILE"
}

runIt() {
 eval "$@" 2>&1 | tee -a "$LOG_FILE"
}

defaultRead() {
 defaults read "$DEFAULTS_FILE" "$1" 2>/dev/null
}

myInstall() {
 until [ -e "$1" ]; do
  case $2 in
   policy)
    runIt "/usr/local/bin/jamf policy -event $3"
   ;;
   install)
    runIt "/usr/local/Installomator/Installomator.sh $3 NOTIFY=silent GITHUBAPI=$GITHUB_API"
   ;;
   *)
    logIt "Error: myInstall: \$2 must be either policy or install, soft failing this install attempt by touching the check file"
    touch "$1"
   ;;
  esac
  if [ ! -e "$1" ]; then
   sleep 5
  fi
 done
}

# Lets get started

until [ -e "$DEFAULTS_FILE" ]; do
 sleep 1
done

case $1 in
 /)
  # set time
  SYSTEM_TIME_ZONE="${"$( defaultRead systemTimeZone )":-"$( systemsetup -gettimezone | awk '{print $NF}' )"}"
  #"# this comment fixes an Xcode display bug
  SYSTEM_TIME_SERVER="${"$( defaultRead systemTimeServer )":-"$( systemsetup -getnetworktimeserver | awk '{print $NF}' )"}"
  #"# this comment fixes an Xcode display bug
  runIt "/usr/sbin/systemsetup -settimezone '"$SYSTEM_TIME_ZONE"'"
  sleep 5
  runIt "/usr/sbin/systemsetup -setnetworktimeserver $SYSTEM_TIME_SERVER"
  sleep 5
  runIt "/usr/bin/sntp -Ss $SYSTEM_TIME_SERVER"
  sleep 1

  # Install completeEnrolment
  logIt "Installing $C_ENROLMENT..."
  ditto "$0" "$C_ENROLMENT"
  
  # Install Rosetta (just in case, and account for it being missing in macOS 28+)
  if [ "$( arch )" = "arm64" ] && [ $(sw_vers -productVersion | cut -d '.' -f 1) -lt 28 ]; then
   logIt "Installing Rosetta on Apple Silicon..."
   runIt "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
  fi
  
  

  # Setup Login Window
  defaults write "$LOGIN_DIALOG_PLIST" LimitLoadToSessionType -array "LoginWindow"
  defaults write "$LOGIN_DIALOG_PLIST" Label "$DEFAULTS_NAME.loginwindow"
  defaults write "$LOGIN_DIALOG_PLIST" RunAtLoad -bool TRUE
  defaults write "$LOGIN_DIALOG_PLIST" ProgramArguments -array "$C_ENROLMENT" "loginWindow"
  chmod ugo+r "$LOGIN_DIALOG_PLIST"
  
  
  launchctl load -S LoginWindow "$LAUNCHAGENT"
  
  # Executed by Jamf Pro
  # Load config profile settings and save them for later use in a more secure location, do the same
  # for supplied options such as passwords, only attempt to store them in the Keychain (such as
  # email, and API passwords). This is to allow for hopefully a more secure process, but limiting
  # the access to some of the information to say only during the first 24 hours (at least coming
  # from Jamf Pro that way).
  case $WHO_LOGGED in
   _mbsetupuser)
    # Get setup quickly and start atLoginWindow for initial step tracking followed by a restart.
    # This includes creating a temporary admin account with automatic login status to get the first
    # Secure Token, without which so many things will break.
   ;;
   *)
    # We will need the logins of an account with a Secure Token to proceed, so lets ask, in this
    # instance, no need to restart, once the login details are collected, just start processing.
   ;;
  esac
 ;;
 *)
  # load saved settings
 ;|
 loginWindow)
  # triggered loginwindow
 ;; # or ;& ?
 startProcessing)
 ;; # or ;& ?
 continueProcessing)
 ;;
 atRestart)
  # continued processing, possibly after restarting?
 ;;
 cleanUp)
  # A clean up routine
 ;;
 emailError)
 ;; # ?
 emailSuccess)
 ;; # ?
 *)
  
 ;;
esac

