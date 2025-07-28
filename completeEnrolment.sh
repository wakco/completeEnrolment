#!/bin/zsh -f

# Commands
# For anything outside /bin /usr/bin, /sbin, /usr/sbin

C_JAMF="/usr/local/bin/jamf"
C_INSTALL="/usr/local/Installomator/Installomator.sh"
C_DIALOG="/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog"
C_MKUSER="/usr/local/bin/mkuser"
C_ENROLMENT="/usr/local/bin/completeEnrolment"

# Variables

DEFAULTS_NAME="completeEnrolment"
# If you change DEFAULTS_NAME, make sure the domain in the config profiles matches, or it won't work
DEFAULTS_PLIST="$DEFAULTS_NAME.plist"
LIB="/Library"
PREFS="/private/var/root$LIB/Preferences"
DEFAULTS_FILE="$LIB/Managed Preferences/$DEFAULTS_PLIST"
CLEANUP_FILES=( "$C_ENROLMENT" )
STARTUP_PLIST="$LIB/LaunchDaemons/$DEFAULTS_PLIST"
CLEANUP_FILES+=( "$STARTUP_PLIST" )
LOGIN_PLIST="$LIB/LaunchAgents/$DEFAULTS_PLIST"
CLEANUP_FILES+=( "$LOGIN_PLIST" )
SETTINGS_PLIST="$PREFS/$DEFAULTS_PLIST"
CLEANUP_FILES+=( "$SETTINGS_PLIST" )
CACHE="$LIB/Caches/completeEnrolment"
mkdir -p "$CACHE"
CLEANUP_FILES+=( "$CACHE" )
JAMF_URL="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url )"
JAMF_SERVER="$( echo "$JAMF_URL" | awk -F '(/|:)' '{ print $4 }' )"
SELF_SERVICE="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null )"
if [ "$SELF_SERVICE" = "" ]; then
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

# prefer jq
if [ -e /usr/bin/jq ]; then
 # jq "alias"
 jq() {
  /usr/bin/jq -Mr ".$1 // empty" "$TRACKER_JSON"
 }
 readJSON() {
  printf '%s' "$1" | /usr/bin/jq -r ".$2 // empty"
 }
else
 # makeshift jq replacement
 jq() {
  # JavaScript method can't do key[.otherkey], and doesn't output json format, so must be weary
  #  currently only using listitem[.currentitem].key so we replace .currentitem here with its
  #  contents using sed
  if [[ "$1" == *'[.currentitem'* ]]; then
   local GET_IT="$( echo "$1" | sed "s/\[\.currentitem/[$( jq 'currentitem' )/" )"
  else
   local GET_IT="$1"
  fi
  JSON="$( cat "$TRACKER_JSON" )" osascript -l 'JavaScript' \
   -e 'const env = $.NSProcessInfo.processInfo.environment.objectForKey("JSON").js' \
   -e "JSON.parse(env).$GET_IT"
 }
 readJSON() {
  JSON="$1" osascript -l 'JavaScript' \
   -e 'const env = $.NSProcessInfo.processInfo.environment.objectForKey("JSON").js' \
   -e "JSON.parse(env).$2"
 }
fi

# Log File

# This will Generate a number of log files based on the task and when they started.

LOG_FILE="$LIB/Logs/$DEFAULTS_NAME-$( if [ "$1" = "/" ]; then echo "Jamf" ; else echo "$1" ; fi )-$WHO_LOGGED-$( date "+%Y-%m-%d %H-%M-%S %Z" ).log"

# Functions

errorIt() {
 logIt "$2" >&2
 logIt "Removing: $CLEANUP_FILES"
 eval "rm -rf $CLEANUP_FILES"
 exit $1
}

logIt() {
 echo "$(date) - $@" 2>&1 | tee -a "$LOG_FILE"
}
logIt "###################### completeEnrolment started with $1."

defaultRead() {
 defaults read "$DEFAULTS_FILE" "$1" 2>/dev/null
}

defaultReadBool() {
 if [ "$( defaultRead $1 )" = "1" ]; then
  echo "true"
 else
  echo "false"
 fi
}

listRead() {
 plutil -extract "$1" raw -o - "$DEFAULTS_FILE" 2>/dev/null
}

settingsPlist() {
 eval "defaults $1 '$SETTINGS_PLIST' '$2' '$3' '$4'" 2>/dev/null
}

readSaved() {
 settingsPlist read "$1" | base64 -d
}

runIt() {
 local THE_RESULT="$( eval "$1" 2>&1 )"
 local THE_RETURN=$?
 echo "$(date) --- Executed '${2:-"$1"}' which returned signal $THE_RETURN and:\n$THE_RESULT" | tee -a "$LOG_FILE"
 return $THE_RETURN
}

infoBox() {
 INFOBOX="**macOS $( sw_vers -productversion )** on  <br>$( scutil --get ComputerName )  <br><br>"
 INFOBOX+="**Started:**  <br>$( jq startdate )  <br><br>"
 if [ "$START_TIME" != "" ]; then
  INFOBOX+="**Restarted:**  <br>$( date -jr "$START_TIME" "+%d/%m/%Y %H:%M" )  <br><br>"
 fi
 if [ "$FINISH_TIME" != "" ]; then
  INFOBOX+="**Estimated Finish:**  <br>$( date -jr "$FINISH_TIME" "+%d/%m/%Y %H:%M" )  <br><br>"
 fi
 if [ "$NEW_INDEX" != "" ]; then
  INFOBOX+="**Apps to Install:** $NEW_INDEX  <br><br>"
 fi
 if [ "$SUCCESS_COUNT" != "" ]; then
  INFOBOX+="**Installed:** $SUCCESS_COUNT  <br><br>"
 fi
  if [ "$FAILED_COUNT" != "" ]; then
  INFOBOX+="**Failed:** $FAILED_COUNT  <br><br>"
 fi
 if [ "$FULLSUCCESS_COUNT" != "" ]; then
  INFOBOX+="**Completed Tasks:** $FULLSUCCESS_COUNT  <br><br>"
 fi
 track string infobox "$INFOBOX"
 plutil replace infobox -string "$INFOBOX" "$LOG_JSON"
 if [ ! -e "$TRACKER_RUNNING" ]; then
  echo "infobox: $INFOBOX" >> "$TRACKER_COMMAND"
  sleep 0.1
 fi
 logIt "$INFOBOX"
}

track() {
 local THE_STRING="$( echo "$3" | tr -d '"' )"
 case $1 in
  bool|integer|string)
   logIt "Updating $2 of type $1 to: $THE_STRING"
   eval "plutil -replace $2 -$1 \"$THE_STRING\" '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "$2: $THE_STRING" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
  ;;
  new)
   THE_STRING="$( echo "$2" | tr -d '"' )"
   logIt "Adding task: $THE_STRING"
   eval "plutil -insert listitem -json \"{\\\"title\\\":\\\"$THE_STRING\\\"}\" -append '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "listitem: add, title: $THE_STRING" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
   TRACKER_ITEM=${$( jq 'currentitem' ):--1}
   ((TRACKER_ITEM++))
   track integer currentitem $TRACKER_ITEM
   logIt "Added task #$TRACKER_ITEM: $THE_STRING"
  ;;
  update)
   TRACKER_ITEM=${$( jq 'currentitem' ):-0}
   logIt "Updating $2 of task #$TRACKER_ITEM \"$( jq 'listitem[.currentitem].title' )\" to: $THE_STRING"
   eval "plutil -replace listitem.$TRACKER_ITEM.$2 -string \"$THE_STRING\" '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "listitem: index: $TRACKER_ITEM, $2: $THE_STRING" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
  ;;
 esac
}

# for trackIt and repeatIt:
# command type (command/policy/label), (shell command, jamf policy trigger, or Installomator label),
#  status confirmation type, file to check for (for status confirmation type: file), Team ID
trackIt() {
 track update status wait
 case $3 in
  stamp)
   if [ "$RECON_DATE" = "" ] || [ $RECON_DATE -gt $(($RECON_DATE+$PER_APP*60)) ]; then
    RECON_DATE=$( date "+%s" )
   else
    return 0
   fi
  ;&
  date)
   track update statustext "Checking..."
  ;;
  pause)
   track update statustext "Paused."
  ;;
  *)
   if [ COUNT = "" ]; then
    track update statustext "Running..."
   else
    track update statustext "Attempting #$COUNT Running..."
   fi
  ;;
 esac
 case $1 in
  command)
   runIt "$2"
  ;;
  policy)
   runIt "$C_JAMF policy -event $2"
  ;;
  install)
   runIt "$C_INSTALL $2 NOTIFY=silent $GITHUBAPI"
  ;;
  selfService)
   runIt "launchctl asuser $( id -u $WHO_LOGGED ) open -j -a '$SELF_SERVICE' -u '$2'"
  ;;
 esac
 THE_RESULT=$?
 case $3 in
  date)
   track update statustext "Last Updated - $(date)"
  ;|
  pause)
   track update statustext "Resumed."
  ;|
  date|pause)
   track update status pending
   return 0
  ;;
  *)
   track update statustext "Confirming..."
   THE_TEST=false
  ;|
  appstore)
   THE_TEST="CHECKAPP=\"\$( spctl -a -vv '$4' 2>&1 )\" && [[ \"\$CHECKAPP\" = *'Mac App Store'* ]]"
  ;|
  teamid)
   if CHECKAPP="$( spctl -a -vv "$4" 2>&1 )"; then
    if [[ "$CHECKAPP" = *"($5)"* ]]; then
     THE_TEST=true
    else
     track update status success
     track update statustext "Completed, but Team ID ($5) didn't match installed ID ($( echo "$CHECKAPP" | awk '/origin=/ {print $NF }' | tr -d '()' ))"
     return 0
    fi
   fi
  ;|
  result)
   THE_TEST="[ '$THE_RESULT' -eq 0 ]"
  ;|
  file)
   THE_TEST="[ -e '$4' ]"
  ;|
  test)
   THE_TEST="$4"
  ;|
  *)
   if eval "$THE_TEST" 2>&1 >> "$LOG_FILE"; then
    track update status success
    track update statustext "Completed"
    return 0
   else
    track update status fail
    if [ $COUNT = "" ]; then
     track update statustext "Failed, waiting for next attempt..."
    else
     track update statustext "Attempt #$COUNT Failed... waiting for next attempt..."
    fi
    return 1
   fi
  ;;
 esac
}

repeatIt() {
 COUNT=1
 until [ $COUNT -gt $PER_APP ] || trackIt "$1" "$2" "$3" "$4"; do
  sleep 5
  ((COUNT++))
 done
 if [ $COUNT -gt $PER_APP ]; then
  track update status error
  track update statustext "Failed after $PER_APP attempts"
  unset COUNT
  return 1
 else
  track update status success
  if [[ "$3" != (date|pause) ]]; then
   track update statustext "Completed"
  fi
  unset COUNT
  return 0
 fi
}

# title, command type (command/policy/label), (shell command, jamf policy trigger, or Installomator
#  label), subtitle (where command type is secure), status confirmation type, file to check for (for
#  status confirmation type: file)
trackNow() {
 track new "$1"
 case $2 in
  secure)
   track update subtitle "$4"
   repeatIt command "$3" "$5" "$6"
  ;;
  policy)
   track update subtitle "Jamf Event - $3"
   repeatIt "$2" "$3" "$4" "$5"
  ;;
  install)
   track update subtitle "Installomator Label - $3"
   repeatIt "$2" "$3" "$4" "$5"
  ;;
  *)
   track update subtitle "$3"
   repeatIt "$2" "$3" "$4" "$5"
  ;;
 esac
 THE_RESULT=$?
 # Process error here?
 return $THE_RESULT
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
TRACKER_JSON="$PREFS/completeEnrolment-tracker.json"
LOG_JSON="$PREFS/completeEnrolment-log.json"
TRACKER_RUNNING="/tmp/completeEnrolment.DIALOG.run"
touch "$TRACKER_COMMAND" "$TRACKER_JSON" "$LOG_JSON"
CLEANUP_FILES+=( "$TRACKER_JSON" )
CLEANUP_FILES+=( "$LOG_JSON" )
TEMP_ADMIN="${"$( defaultRead tempAdmin )":-"setup_admin"}"
TEMP_NAME="${"$( defaultRead tempName )":-"Setup Admin"}"
LAPS_ADMIN="${"$( defaultRead lapsAdmin )":-"laps_admin"}"
LAPS_NAME="${"$( defaultRead lapsName )":-"LAPS Admin"}"
PER_APP=${"$( defaultRead perAPP )":-"5"}

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
   GITHUBAPI=" GITHUBAPI=$( echo "$4" | base64 -d )"
   settingsPlist write github -string "$4"
  fi
  if [ "$5" = "" ]; then
   TEMP_PASS="$( echo "setup" | base64 )"
  else
   TEMP_PASS="$5"
  fi
  settingsPlist write temp -string "$TEMP_PASS"
  if [ "$6" = "" ]; then
   LAPS_PASS="$TEMP_PASS"
  else
   LAPS_PASS="$6"
  fi
  settingsPlist write laps -string "$LAPS_PASS"
  if [ "$7" = "" ] || [ "$8" = "" ]; then
   if [ "$WHO_LOGGED" != "_mbsetupuser" ]; then
    "$C_DIALOG" --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: missing Jamf Pro API login details"
   fi
   errorIt 2 "API details are required for access to the \$JAMF_ADMIN password, the following was supplied:\nAPI ID: $7\nAPI Secret: $8"
  else
   settingsPlist write apiId -string "$7"
   settingsPlist write apiSecret -string "$8"
  fi
  EMAIL_PASS="${9:-""}"
  settingsPlist write email -string "$9"


  # Initialise dialog setup file, our "tracker"
  # although plutil can create an empty json, it can't insert into it, incorrectly mistaking the
  # file to be in another format (OpenStep), so we'll just add an item with an echo
  echo '{"title":"none"}' > "$TRACKER_JSON"
  track string title "Welcome to ${"$( defaultRead corpName )":-"The Service Desk"}"
  track string message "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE"
  track string icon "$DIALOG_ICON"
  track string commandfile "$TRACKER_COMMAND"
  track string position "bottom"
  track string height "75%"
  track string width "80%"
  track bool blurscreen true
  ditto "$TRACKER_JSON" "$LOG_JSON"
  plutil -insert listitem -array "$TRACKER_JSON"
  track string liststyle "compact"
  plutil -replace displaylog -string "$LOG_FILE" "$LOG_JSON"

  # set time
  TIME_ZONE="${"$( defaultRead systemTimeZone )":-"$( systemsetup -gettimezone | awk "{print \$NF}" )"}"
  trackNow "Setting Time Zone" \
   command "/usr/sbin/systemsetup -settimezone '$TIME_ZONE'" \
   result
  sleep 5
  SYSTEM_TIME_SERVER="${"$( defaultRead systemTimeServer )":-"$( systemsetup -getnetworktimeserver | awk "{print \$NF}" )"}"
  trackNow "Setting Network Time Sync server" \
   command "/usr/sbin/systemsetup -setnetworktimeserver '$SYSTEM_TIME_SERVER'" \
   result
  sleep 5
  trackNow "Synchronising the Time" \
   command "/usr/bin/sntp -Ss '$SYSTEM_TIME_SERVER'" \
   result
  sleep 5
  
  # Load infoBox
  track string starttime "$( date "+%s" )"
  track string startdate "$( date -jr "$( jq starttime )" "+%d/%m/%Y %H:%M" )"
  infoBox
  
  # Install Rosetta (just in case, and skip it for macOS 28+)
  if [ "$CPU_ARCH" = "arm64" ] && [ $(sw_vers -productVersion | cut -d '.' -f 1) -lt 28 ]; then
   trackNow "Installing Rosetta for Apple Silicon Mac Intel compatibility" \
    command "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" \
    file "/Library/Apple/usr/libexec/oah/libRosettaRuntime"
   sleep 5
  fi
  
  # Install initial file
  INSTALL_POLICY="${"$( defaultRead policyInitialFiles )":-"installInitialFiles"}"
  trackNow "Installing Initial Files" \
   policy "$INSTALL_POLICY" \
   file "$DIALOG_ICON"
  infoBox

  # Install Installomator
  # This can be either the custom version from this repository, or the script that installs the
  # official version.
  INSTALL_POLICY="${"$( defaultRead policyInstallomator )":-"installInstallomator"}"
  trackNow "Installing Installomator" \
   policy "$INSTALL_POLICY" \
   file "/usr/local/Installomator/Installomator.sh"
  infoBox
  
  # Install swiftDialog
  trackNow "Installing swiftDialog (the software generating this window)" \
   install dialog \
   file "$C_DIALOG"
  
  
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
        
    # Preparing the Login window
    # These settings fix a quirk with automated where the login window instead of having a
    # background, ends up displaying a grey background these two settings apparently repait that.
    runIt "defaults write $LIB/Preferences/com.apple.loginwindow.plist AdminHostInfo -string HostName"
    runIt "defaults write $LIB/Preferences/com.apple.loginwindow.plist SHOWFULLNAME -bool true"
        
    # Restart the login window
    runIt "/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow.plist LoginwindowText 'Enrolled at $( /usr/bin/profiles status -type enrollment | /usr/bin/grep server | /usr/bin/awk -F '[:/]' '{ print $5 }' )\nplease wait while initial configuration in performed...\nThis computer will restart shortly.'"
    sleep 5
    
    # only kill the login window if it is already running
    if [ "$( pgrep -lu "root" "loginwindow" )" != "" ]; then
     runIt "pkill loginwindow"
    fi

    # start loginwindow
    sleep 2
    defaults write "$LOGIN_PLIST" LimitLoadToSessionType -array "LoginWindow"
    defaults write "$LOGIN_PLIST" Label "$DEFAULTS_NAME.loginwindow"
    defaults write "$LOGIN_PLIST" RunAtLoad -bool TRUE
    defaults write "$LOGIN_PLIST" ProgramArguments -array \
     "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog" \
     "--loginwindow" "--button1disabled" "--button1text" "none" "--jsonfile" "$TRACKER_JSON"
    chmod ugo+r "$LOGIN_PLIST"
    sleep 2
    touch "$TRACKER_RUNNING"
    launchctl load -S LoginWindow "$LOGIN_PLIST"
    sleep 2

    MKUSER_OPTIONS=""
   ;|
   ^_mbsetupuser)
    # We will need the login details of a Volume Owner (an account with a Secure Token) to proceed,
    # so we'll ask for it, and in this instance, no need to restart, once the login details are
    # collected, start the dialog and just start processing (after setting the computer name).
    # add completesetup with volume owner details, without automatic login.
    "$C_DIALOG"
    
    # code here to be completed
    runIt "'$C_ENROLMENT' startDialog >> /dev/null 2>&1 &"
    
    MKUSER_OPTIONS="--secure-token-admin-account-name '$loggedinusername' --secure-token-admin-password '$loggedinpassword'"
   ;|
   *)
    # Setup Startup after restart
    trackNow "Add this script to startup process" \
     secure "defaults write '$STARTUP_PLIST' Label '$DEFAULTS_NAME' ; defaults write '$STARTUP_PLIST' RunAtLoad -bool TRUE ; defaults write '$STARTUP_PLIST' ProgramArguments -array '$C_ENROLMENT' ; chmod go+r '$STARTUP_PLIST'" "Creating '$STARTUP_PLIST'" \
     file "$STARTUP_PLIST"

    # unbind from Active Directory (if bound)
    if [ "$( ls /Library/Preferences/OpenDirectory/Configurations/Active\ Directory | wc -l )" -gt 0 ]; then
     POLICY_UNBIND="$( defaultRead policyADUnbind )"
     if [ "$POLICY_UNBIND" = "" ]; then
      trackNow "Unbinding from Active Directory - Required for account management, and computer (re)naming." \
       command "/usr/sbin/dsconfigad -leave -force" \
       test '[ "$( ls /Library/Preferences/OpenDirectory/Configurations/Active\ Directory | wc -l )" -eq 0 ]'
     else
      trackNow "Unbinding from Active Directory - Required for account management, and computer (re)naming." \
       policy "$POLICY_UNBIND" \
       test '[ "$( ls /Library/Preferences/OpenDirectory/Configurations/Active\ Directory | wc -l )" -eq 0 ]'
     fi
    fi

    # set computername
    INSTALL_POLICY="${"$( defaultRead policyComputerName )":-"fixComputerName"}"
    COMPUTER_NAME="$( scutil --get ComputerName )"
    trackNow "Setting computer name" \
     policy "$INSTALL_POLICY" \
     test '[ "$COMPUTER_NAME" != "$( scutil --get ComputerName )" ]'
    infoBox
    
    # perform a recon
    trackNow "Updating Inventory" \
     command "'$C_JAMF' recon" \
     test true

    # install mkuser
    trackNow "Installing mkuser" \
     install mkuser \
     file "$C_MKUSER"
    
    # Add complete setup
    trackNow "Creating Complete Setup Account" \
     secure "'$C_MKUSER' --username '$TEMP_ADMIN' --password '$( settingsPlist read temp | base64 -d )' --real-name '$TEMP_NAME' --home /Users/$TEMP_ADMIN --hidden userOnly --skip-setup-assistant firstLoginOnly --automatic-login --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes $MKUSER_OPTIONS" "Creating username $TEMP_ADMIN with mkuser" \
     file "/Users/$TEMP_ADMIN"
    
   ;|
   _mbsetupuser)
    # Restart, and record it as a task
    shutdown -r +1 &
    trackNow "Restarting for Application Installation" \
     none 'shutdown -r +1 &' \
     date
    sleep 5
    rm -rf "$LOGIN_PLIST" "$TRACKER_RUNNING"
    # if we get a dialog going, keep it open for at least half the time?
    # sleep 30
   ;;
   *)
    # trigger processing
    runIt "'$C_ENROLMENT' process >> /dev/null 2>&1"
   ;;
  esac
  unsetopt extended_glob
  if ${$( defaultReadBool emailJamfLog ):-false} ; then
   # cannot use errorIt to exit here, since 1. this is not an error, and 2. because errorIt will
   # also cleanUp
   logIt "Exiting with an error signal as requested in the configuration."
   exit 1
  else
   exit 0
  fi
 ;;
 startDialog)
  # to open the event tracking dialog
  TRACKER=true
  echo > "$TRACKER_COMMAND"
  until [[ "$( tail -n1 "$TRACKER_COMMAND" )" = "quit:" ]]; do
   if $TRACKER; then
    touch "$TRACKER_RUNNING"
    logIt "Starting Progress Dialog..."
#    runIt "'$C_DIALOG' --loginwindow --jsonfile '$TRACKER_JSON'"
    runIt "'$C_DIALOG' --jsonfile '$TRACKER_JSON' --button1text 'Show Log...'"
    rm -f "$TRACKER_RUNNING"
    TRACKER=false
   else
    logIt "Starting Log view Dialog..."
#    runIt "'$C_DIALOG' --loginwindow --jsonfile '$LOG_JSON'"
    runIt "'$C_DIALOG' --jsonfile '$LOG_JSON' --button1text 'Show Tasks...'"
    TRACKER=true
   fi
   
  done
 ;;
 *)
  # load saved settings
  if [ "$( settingsPlist read github )" = "" ]; then
   GITHUBAPI=""
  else
   GITHUBAPI=" GITHUBAPI=$( readSaved github )"
  fi
 ;|
 process)
  # clear the LoginwindowText
  runIt "/usr/bin/defaults delete /Library/Preferences/com.apple.loginwindow.plist LoginwindowText"
  # update LOG_JSON to identify and follow the correct log file.
  plutil -replace displaylog -string "$LOG_FILE" "$LOG_JSON"
  track string message "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE"
  plutil -replace message -string "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE" "$LOG_JSON"
  START_TIME=$( date "+%s" )
  infoBox

  # wait for Finder
  while [ "$( pgrep "Finder" )" = "" ]; do
   sleep 1
  done
  
  # reset WHO_LOGGED as starting before the Finder may have collecting the wrong information
  if [ "$( who | grep console | wc -l )" -gt 1 ]; then
   WHO_LOGGED="$( who | grep -v mbsetupuser | grep -m1 console | cut -d " " -f 1 )"
  else
   WHO_LOGGED="$( who | grep -m1 console | cut -d " " -f 1 )"
  fi
  
  sleep 5
  
  # now is a good time to start Self Service
  launchctl asuser $( id -u $WHO_LOGGED ) osascript -e "tell application \"Finder\" to open POSIX file \"$SELF_SERVICE\""
  sleep 5

  # and close Finder & Dock if we just started up (i.e. if WHO_LOGGED = TEMP_ADMIN)
  if [ "$WHO_LOGGED" = "$TEMP_ADMIN" ]; then
   track update status success
   launchctl bootout gui/$( id -u $WHO_LOGGED )/com.apple.Dock.agent
   launchctl bootout gui/$( id -u $WHO_LOGGED )/com.apple.Finder
  fi
  
  # Start Tracker dialog
  if [ "$( pgrep -lu "root" "Dialog" )" = "" ]; then
   runIt "'$C_ENROLMENT' startDialog >> /dev/null 2>&1 &"
  fi
  sleep 5
  
  # finishing setting up admin accounts
  # Add JSS ADMIN
  # This will load the $JAMF_ADMIN and $JAMF_PASS login details
  JAMF_AUTH_TOKEN="$( echo "$( curl -s --location --request POST "${JAMF_URL}api/oauth/token" \
   --header 'Content-Type: application/x-www-form-urlencoded' \
   --data-urlencode "client_id=$( readSaved apiId )" \
   --data-urlencode 'grant_type=client_credentials' \
   --data-urlencode "client_secret=$( readSaved apiSecret )" )" | /usr/bin/jq -Mr ".access_token" )"
  if [[ "$JAMF_AUTH_TOKEN" = *httpStatus* ]]; then
   "$C_DIALOG" --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: unable to login to Jamf Pro API"
   errorIt 2 "This should not have happened, are the API ID/Secret details correct?\nResponse from $JAMF_URL:\n$JAMF_AUTH_TOKEN"
  fi
  sleep 1

  JAMF_ACCOUNTS="$( curl -s "${JAMF_URL}api/v2/local-admin-password/$( defaultRead managementID )/accounts" \
   -H "accept: application/json" -H "Authorization: Bearer $JAMF_AUTH_TOKEN" )"
  logIt "checking for JMF account in:\n$JAMF_ACCOUNTS\n"
  for (( i = 0; i < $( readJSON "$JAMF_ACCOUNTS" "totalCount" ); i++ )); do
   if [ "$( readJSON "$JAMF_ACCOUNTS" "results[$i].userSource" )" = "JMF" ]; then
    JAMF_ADMIN="$( readJSON "$JAMF_ACCOUNTS" "results[$i].username" )"
    JAMF_GUID="$( readJSON "$JAMF_ACCOUNTS" "results[$i].guid" )"
    break
   fi
  done
  if [ -z "$JAMF_ADMIN" ] || [ -z "$JAMF_GUID" ]; then
   "$C_DIALOG" --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: unable to get management account username from Jamf Pro API"
   errorIt 2 "this should not have happened, unable to get Jamf Managed Account Details:\n$JAMF_AUTH_TOKEN\n$JAMF_ACCOUNTS"
  fi
  sleep 1

  JAMF_PASS="$( readJSON "$( curl -s "${JAMF_URL}api/v2/local-admin-password/$( defaultRead managementID )/account/$JAMF_ADMIN/$JAMF_GUID/password" \
   -H "accept: application/json" -H "Authorization: Bearer $JAMF_AUTH_TOKEN" )" "password" )"
  if [ -z "$JAMF_PASS" ]; then
   "$C_DIALOG" --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: unable to get management account password from Jamf Pro API"
   errorIt 2 "this should not have happened, unable to get Jamf Managed Account Password:\n$JAMF_AUTH_TOKEN\n$JAMF_ACCOUNTS"
  fi

  trackNow "Creating $JAMF_ADMIN Account" \
  secure "'$C_MKUSER' --username $JAMF_ADMIN --password '$JAMF_PASS' --real-name '$JAMF_ADMIN Account' --home /private/var/$JAMF_ADMIN --hidden userOnly --skip-setup-assistant firstLoginOnly --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes --secure-token-admin-account-name '$TEMP_ADMIN' --secure-token-admin-password '$( readSaved temp )'" "Creating username $JAMF_ADMIN" \
   file "/private/var/$JAMF_ADMIN"
  # Add or update LAPS ADMIN
  if [ -e "/Users/$LAPS_ADMIN" ]; then
   trackNow "Securing $LAPS_NAME Account" \
    secure "dscl . change '/Users/$LAPS_ADMIN' NFSHomeDirectory '/Users/$LAPS_ADMIN' '/private/var/$LAPS_ADMIN' ; mv '/Users/$LAPS_ADMIN' '/private/var/$LAPS_ADMIN' ; sysadminctl -secureTokenOn '"$LAPS_ADMIN"' -password '$( readSaved laps )' -adminUser '$TEMP_ADMIN' -adminPassword '$( readSaved temp )'" "Moving and securing $LAPS_ADMIN"\
    result

  else
   trackNow "Creating $LAPS_NAME Account" \
    secure "'$C_MKUSER' --username $LAPS_ADMIN --password '$( readSaved laps )' --real-name '$LAPS_NAME' --home /private/var/$LAPS_ADMIN --hidden userOnly --skip-setup-assistant firstLoginOnly --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes --secure-token-admin-account-name '$TEMP_ADMIN' --secure-token-admin-password '$( readSaved temp )'" "Creating username $LAPS_ADMIN" \
    file "/private/var/$LAPS_ADMIN"
  fi
 
  if [ "$( defaults read "$DEFAULTS_FILE" installs 2>/dev/null )" != "" ]; then
     
   track new "Task List"
   track update status pending
   track update statustext "Loading..."
   track update subtitle "Loading the task list from the config profile."
   # Identify index of first cycling check item, until now each item would retry automatically
   #  immediately for up to 5 time, now we want to switch to trying everything else before retrying,
   #  and keep going until everything is successful, or a specified timeout (at 5 minutes per item?).
   TRACKER_START=${$( jq 'currentitem' ):--1}
   track integer startitem $((TRACKER_START+1))
   
   # load software installs
   NEW_INDEX=0
   infoBox
   track update status wait
   until [ $NEW_INDEX -ge $( listRead "installs" ) ]; do
    # Cheating by using TRACKER_START to update the Task List loading entry
    plutil -replace listitem.$TRACKER_START.statustext -string "Loading task #$((NEW_INDEX+1))" "$LOG_JSON"
    echo "listitem: index: $TRACKER_START, statustext: Loading task #$((NEW_INDEX+1))"
    sleep 0.1
    
    # for each item in config profile
    track new "$( listRead "installs.$NEW_INDEX.title" )"
    COMMAND="$( listRead "installs.$NEW_INDEX.command" )"
    track update command "$COMMAND"
    track update commandtype "$( listRead "installs.$NEW_INDEX.commandtype" )"
    SUBTITLE="$( listRead "installs.$NEW_INDEX.subtitle" )"
    track update suppliedsubtitle "$SUBTITLE"
    SUBTITLE_TYPE="$( listRead "installs.$NEW_INDEX.subtitletype" )"
    track update subtitletype "$SUBTITLE_TYPE"
    case $COMMAND in
     policy)
      COMMAND="Jamf Event - $COMMAND"
     ;;
     install)
      COMMAND="Installomator Label - $COMMAND"
     ;;
    esac
    case $SUBTITLE_TYPE in
     secure)
      track update subtitle "$SUBTITLE"
     ;;
     command)
      track update subtitle "$COMMAND"
     ;;
     combine)
      track update subtitle "$SUBTITLE - $COMMAND"
     ;;
    esac
    track update successtype "$( listRead "installs.$NEW_INDEX.successtype" )"
    track update successtest "$( listRead "installs.$NEW_INDEX.successtest" )"
    track update successteam "$( listRead "installs.$NEW_INDEX.successteam" )"
    track update subtitle "$( listRead "installs.$NEW_INDEX.subtitle" )"
    THE_ICON="$( listRead "installs.$NEW_INDEX.icon" )"
    if [ "$THE_ICON" = "" ]; then
     track update icon none
    else
     case $THE_ICON; in
      http*)
       # Cache the icon locally, as scrolling the window causes swiftDialog to reload the icons, which is
       #  not so good when they are hosted, so downloading them to a folder and directing swiftDialog to
       #  the downloaded copy makes much more sense.
       ICON_NAME="$CACHE/$( basename "$THE_ICON" )"
       runIt "curl -s -o '$ICON_NAME' '$THE_ICON'"
       THE_ICON="$CACHE/icon-$NEW_INDEX-$( js 'currentitem' ).png"
       runIt "sips -s format png '$ICON_NAME' --out '$THE_ICON'"
      ;&
      *)
       track update icon "$THE_ICON"
      ;;
     esac
    fi
    track update backuptype "$( listRead "installs.$NEW_INDEX.backuptype" )"
    track update backupcommand "$( listRead "installs.$NEW_INDEX.backupcommand" )"
    track update status pending
    track update statustext "waiting to install..."
    infoBox
    ((NEW_INDEX++))
   done
   track new "Pause for 30 seconds"
   track update command "sleep 30"
   track update commandtype command
   track update subtitle "Pause for 30 seconds before checking again."
   track update successtype "pause"
   track new "Inventory Update"
   track update command "'$C_JAMF' recon"
   track update commandtype command
   track update subtitle "Updates inventory once every $PER_APP minutes"
   track update successtype "stamp"
   
   # Restart dialog (just to make sure it got everything).
#   dialog --ontop --timer 15 --title "Reloading..." --message "Reloading the tracking dialog..." --icon none --button1disabled --width 400 --height 150 &
   sleep 2
#   echo "quit:" >> "$TRACKER_COMMAND"
#   sleep 5
#   runIt "'$C_ENROLMENT' startDialog >> /dev/null 2>&1 &"
#   sleep 5
   plutil -replace listitem.$TRACKER_START.statustext -string "Loaded" "$TRACKER_JSON"
   echo "listitem: index: $TRACKER_START, statustext: Loaded" >> "$TRACKER_COMMAND"
   sleep 0.1
   plutil -replace listitem.$TRACKER_START.status -string "success" "$TRACKER_JSON"
   echo "listitem: index: $TRACKER_START, status: success" >> "$TRACKER_COMMAND"
   sleep 0.1
   
   # process software installs
   SUCCESS_COUNT=0
   WAIT_TIME=$(($( plutil -extract "listitem" raw -o - "$TRACKER_JSON" )*$PER_APP*60))
   FINISH_TIME=$(($START_TIME+$WAIT_TIME))
   infoBox
   FINISHED=false
   COUNT=1
   logIt "Total Tasks"
   until [ $SUCCESS_COUNT -eq $NEW_INDEX ] || [ $( date "+%s" ) -gt $FINISH_TIME ]; do
    track integer currentitem $( jq 'startitem' )
    until [ $( jq 'currentitem' ) -ge $( plutil -extract "listitem" raw -o - "$TRACKER_JSON" ) ]; do
     logIt "Running Task $( jq 'currentitem' )"
     if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
      trackIt "$( jq 'listitem[.currentitem].commandtype' )" \
       "$( jq 'listitem[.currentitem].command' )" \
       "$( jq 'listitem[.currentitem].successtype' )" \
       "$( jq 'listitem[.currentitem].successtest' )" \
       "$( jq 'listitem[.currentitem].successteam' )"
      case "$( jq 'listitem[.currentitem].status' )" in
       success)
        ((SUCCESS_COUNT++))
        infoBox
       ;;
       fail)
        FAILED=false
        if [ $COUNT -eq $PER_APP ]; then
         track update commandtype "$( jq 'listitem[.currentitem].backuptype' )"
         track update command "$( jq 'listitem[.currentitem].backupcommand' )"
         COMMAND="$( jq 'listitem[.currentitem].backupcommand' )"
         case $COMMAND in
          policy)
           COMMAND="Jamf Event - $COMMAND"
          ;;
          install)
           COMMAND="Installomator Label - $COMMAND"
          ;;
         esac
         case "$( jq 'listitem[.currentitem].subtitletype' )" in
          command)
           track update subtitle "$COMMAND"
          ;;
          combine)
           track update subtitle "$( jq 'listitem[.currentitem].suppliedsubtitle' ) - $COMMAND"
          ;;
         esac
        fi
       ;;
      esac
     fi
     sleep 5
     track integer currentitem $(($( jq 'currentitem' )+1))
    done
    ((COUNT++))
   done
   FULLSUCCESS_COUNT=0
   FAILED_COUNT=0
   track integer currentitem 0
   until [ $( jq 'currentitem' ) -ge $( plutil -extract "listitem" raw -o - "$TRACKER_JSON" ) ]; do
    case "$( jq 'listitem[.currentitem].status' )" in
     pending)
      track update status success
     ;&
     success)
      ((FULLSUCCESS_COUNT++))
     ;;
     fail)
      ((FAILED_COUNT++))
      track update status error
     ;;
    esac
    track integer currentitem $(($( jq 'currentitem' )+1))
   done
   infoBox
   logIt "Success: $FULLSUCCESS_COUNT, Installs: $SUCCESS_COUNT, Failed: $FAILED_COUNT"
  fi
  # Time to send email and finish.

  # disable automatic login if our TEMP_ADMIN is still configured
  if [ "$( defaults read /Library/Preferences/com.apple.loginwindow.plist autoLoginUser 2>/dev/null )" = "$TEMP_ADMIN" ]; then
   runIt "defaults delete /Library/Preferences/com.apple.loginwindow.plist autoLoginUser"
   rm -f /etc/kcpassword
  fi
 ;;
 cleanUp)
  # A clean up routine
  if ${$( defaultReadBool tempKeep ):-false}; then
   TEMP_ADMIN="${"$( defaultRead tempAdmin )":-"setup_admin"}"
   logIt "Removing $TEMP_ADMIN as no longer required."
   sysadminctl -deleteUser "$TEMP_ADMIN" -adminUser "$TEMP_ADMIN" -adminPassword "$( readSaved laps )" >> "$LOG_FILE" 2>&1
  fi
  logIt "Removing: $CLEANUP_FILES"
  eval "rm -rf $CLEANUP_FILES"
 ;;
 *)
  logIt "TEMP_ADMIN = $TEMP_ADMIN"
  runIt "defaults read /Library/Preferences/com.apple.loginwindow.plist autoLoginUser 2>/dev/null"
  if [ "$( defaults read /Library/Preferences/com.apple.loginwindow.plist autoLoginUser 2>/dev/null )" = "$TEMP_ADMIN" ]; then
   runIt "'$C_ENROLMENT' process >> /dev/null 2>&1"
  else
   runIt "'$C_ENROLMENT' cleanUp >> /dev/null 2>&1"
  fi
 ;;
esac
