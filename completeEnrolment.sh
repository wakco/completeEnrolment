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
CACHE="$LIB/Caches/completeEnrolment"
mkdir -p "$CACHE"
CLEANUP_FILES=( "$C_ENROLMENT" )
CLEANUP_FILES+=( "$LOGIN_PLIST" )
CLEANUP_FILES+=( "$STARTUP_PLIST" )
CLEANUP_FILES+=( "$SETTINGS_PLIST" )
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
fi

# Log File

# This will Generate a number of log files based on the task and when they started.

LOG_FILE="$LIB/Logs/$DEFAULTS_NAME-$( if [ "$1" = "/" ]; then echo "Jamf-$WHO_LOGGED" ; else echo "Command-$1" ; fi )-$( date "+%Y-%m-%d %H-%M-%S %Z" ).log"

# Functions

logIt() {
 echo "$(date) - $@" 2>&1 | tee -a "$LOG_FILE"
}
logIt "###################### completeEnrolment started with $1."

defaultRead() {
 defaults read "$DEFAULTS_FILE" "$1" 2>/dev/null
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
 eval "$1" 2>&1 | tee -a "$LOG_FILE"
}

track() {
 case $1 in
  bool|integer|string)
   logIt "Updating $2 of type $1 to: $3"
   eval "plutil -replace $2 -$1 '$3' '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "$2: $3" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
  ;;
  new)
   logIt "Adding task: $2"
   eval "plutil -insert listitem -json '{\"title\":\"$2\"}' -append '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "listitem: add, title: $2" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
   TRACKER_ITEM=${$( jq 'currentitem' ):--1}
   ((TRACKER_ITEM++))
   track integer currentitem $TRACKER_ITEM
   logIt "Added task #$TRACKER_ITEM: $2"
  ;;
  update)
   TRACKER_ITEM=${$( jq 'currentitem' ):-0}
   logIt "Updating $2 of task #$TRACKER_ITEM \"$( jq 'listitem[.currentitem].title' )\" to: $3"
   eval "plutil -replace listitem.$TRACKER_ITEM.$2 -string '$3' '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "listitem: index: $TRACKER_ITEM, $2: $3" >> "$TRACKER_COMMAND"
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
  date)
   track update statustext "Checking..."
  ;;
  pause)
   track update statustext "Paused."
  ;;
  *)
   if [ COUNTDOWN = "" ]; then
    track update statustext "Running..."
   else
    track update statustext "Attempting #$COUNTDOWN Running..."
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
   runIt "$C_INSTALL $2 NOTIFY=silent $GITHUB_API"
  ;;
  selfService)
   runIt "open -j -a '$SELF_SERVICE' -u '$2'"
  ;;
 esac
 THE_RESULT=$?
 case $3 in
  date)
   track update statustext "Last Updated: $(date)"
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
  ;|
  appstore)
   THE_TEST="CHECKAPP=\"\$( spctl -a -vv '$$4' 2>&1 )\" && [[ \"\$CHECKAPP\" = *'Mac App Store'* ]]"
  ;|
  teamid)
   THE_TEST=false
   if CHECKAPP="$( spctl -a -vv '$$4' 2>&1 )"; then
    if [[ "$CHECKAPP" = *"($5)"* ]]; then
     THE_TEST=true
    else
     track update status success
     track update statustext "Completed, but Developer ID ($5) didn't match installed ID ($( echo "$CHECKAPP" | awk '/origin=/ {print $NF }' | tr -d '()' ))"
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
    if [ $COUNTDOWN = "" ]; then
     track update statustext "Failed, waiting for next attempt..."
    else
     track update statustext "Attempt #$COUNTDOWN Failed, waiting for next attempt..."
    fi
    return 1
   fi
  ;;
 esac
}

repeatIt() {
 COUNTDOWN=1
 until [ $COUNTDOWN -eq 6 ] || trackIt "$1" "$2" "$3" "$4"; do
  sleep 1
  ((COUNTDOWN++))
 done
 if [ $COUNTDOWN -eq 6 ]; then
  track update status error
  track update statustext "Failed after 5 attempts"
  unset COUNTDOWN
  return 1
 else
  track update status success
  track update statustext "Completed"
  unset COUNTDOWN
  return 0
 fi
}

# title, command type (command/policy/label), (shell command, jamf policy trigger, or Installomator
#  label), subtitle (where command type is secure), status confirmation type, file to check for (for
#  status confirmation type: file)
trackNow() {
 track new "$1"
 if [ "$2" = "secure" ]; then
  track update subtitle "$4"
  repeatIt command "$3" "$5" "$6"
 else
  track update subtitle "$3"
  repeatIt "$2" "$3" "$4" "$5"
 fi
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
TRACKER_JSON="/private/var/root/completeEnrolment-tracker.json"
LOG_JSON="/private/var/root/completeEnrolment-log.json"
TRACKER_RUNNING="/tmp/completeEnrolment.DIALOG.run"
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
   GITHUBAPI=" GITHUBAPI=$( echo "$4" | base64 -d )"
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
  # file to be in another format (OpenStep), so we'll just add an item with an echo
  echo '{"title":"none"}' > "$TRACKER_JSON"
  track string title "Welcome to ${"$( defaultRead corpName )":-"The Service Desk"}"
  track string message "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE"
  track string icon "$DIALOG_ICON"
  track string commandfile "$TRACKER_COMMAND"
  track string position "bottom"
  track string height "75%"
  track string width "80%"
  ditto "$TRACKER_JSON" "$LOG_JSON"
  plutil -insert listitem -array "$TRACKER_JSON"
  track string liststyle "compact"
  track string button1text "Show Log..."
  plutil -replace button1text -string "Show Progress..." "$LOG_JSON"
  plutil -replace displaylog -string "$LOG_FILE" "$LOG_JSON"

  # set time
  TIME_ZONE="${"$( defaultRead systemTimeZone )":-"$( systemsetup -gettimezone | awk "{print \$NF}" )"}"
  trackNow "Setting Time Zone to '$TIME_ZONE'" \
   command "/usr/sbin/systemsetup -settimezone '$TIME_ZONE'" \
   result
  sleep 5
  SYSTEM_TIME_SERVER="${"$( defaultRead systemTimeServer )":-"$( systemsetup -getnetworktimeserver | awk "{print \$NF}" )"}"
  trackNow "Setting Network Time Sync server to '$SYSTEM_TIME_SERVER'" \
   command "/usr/sbin/systemsetup -setnetworktimeserver $SYSTEM_TIME_SERVER" \
   result
  sleep 5
  trackNow "Sync'ing the Time with $SYSTEM_TIME_SERVER" \
   command "/usr/bin/sntp -Ss $SYSTEM_TIME_SERVER" \
   result
  sleep 5
  
  # Install Rosetta (just in case, and skip it for macOS 28+)
  if [ "$CPU_ARCH" = "arm64" ] && [ $(sw_vers -productVersion | cut -d '.' -f 1) -lt 28 ]; then
   trackNow "Installing Rosetta for Apple Silicon Mac Intel compatibility" \
    command "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" \
    file "/Library/Apple/usr/libexec/oah/libRosettaRuntime"
   sleep 5
  fi
  
  # Install initial file
  INSTALL_POLICY="${"$( defaultRead policyInitialFiles )":-"installInitialFiles"}"
  trackNow "Installing Initial Files with policy: $INSTALL_POLICY"
   policy "$INSTALL_POLICY" \
   filecommand "$DIALOG_ICON"
  # Install Installomator
  # This can be either the custom version from this repository, or the script that installs the
  # official version.
  INSTALL_POLICY="${"$( defaultRead policyInstallomator )":-"installInstallomator"}"
  trackNow "Installing Installomator with policy: $INSTALL_POLICY" \
   policy "$INSTALL_POLICY" \
   file "/usr/local/Installomator/Installomator.sh"
  
  # Install swiftDialog
  trackNow "Installing swiftDialog (the software generating this window) with Installomator" \
   install dialog \
   file "$C_DIALOG"
    
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
    trackNow "Starting swiftDialog" \
     command "launchctl load -S LoginWindow '$LOGIN_PLIST'" \
     file "$TRACKER_RUNNING"
    MKUSER_OPTIONS=""
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
    MKUSER_OPTIONS="--secure-token-admin-account-name '$loggedinusername' --secure-token-admin-password '$loggedinpassword'"
   ;|
   *)
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
    # install mkuser
    trackNow "Installing mkuser with Installomator" \
     install mkuser \
     file "$C_MKUSER"
    
    # Add complete setup
    trackNow "Creating Complete Setup Account" \
     secure "'$C_MKUSER' --username completesetup --password setup --real-name 'Complete Setup' --home /Users/completesetup --hidden userOnly --skip-setup-assistant firstLoginOnly --automatic-login --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes $MKUSER_OPTIONS" "Creating username completesetup" \
     file "/Users/completesetup"
    
    # set computername
    INSTALL_POLICY="${"$( defaultRead policyComputerName )":-"fixComputerName"}"
    COMPUTER_NAME="$( scutil --get ComputerName )"
    trackNow "Setting computer name using policy: $INSTALL_POLICY" \
     policy "$INSTALL_POLICY" \
     test '[ "$COMPUTER_NAME" != "$( scutil --get ComputerName )" ]'
   ;|
   _mbsetupuser)
    # restart by sending quit message to dialog
    defaults write "$STARTUP_PLIST" Label "$DEFAULTS_NAME.startup"
    defaults write "$STARTUP_PLIST" RunAtLoad -bool TRUE
    defaults write "$STARTUP_PLIST" ProgramArguments -array "$C_ENROLMENT" "process"
    chmod ugo+r "$STARTUP_PLIST"
    trackNow "Restarting for Application Installation" \
     command 'echo "quit:" >> "$TRACKER_COMMAND"' \
     result
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
  TRACKER=true
  echo > "$TRACKER_COMMAND" # Must not start the loop with anything in it
  until [[ "$( tail -n1 "$TRACKER_COMMAND" )" = "quit:" ]]; do
   echo > "$TRACKER_COMMAND" # Must not start a dialog with anything in it
   if $TRACKER; then
    touch "$TRACKER_RUNNING"
    "$C_DIALOG" --loginwindow --jsonfile "$TRACKER_JSON" --button1text "Show Log..."
    rm -f "$TRACKER_RUNNING"
    TRACKER=false
   else
    "$C_DIALOG" --loginwindow --jsonfile "$LOG_JSON" --button1text "Show Progress..."
    TRACKER=true
   fi
  done
  if [ "$2" = "-restart" ]; then
   defaults delete "$LOGIN_PLIST" LimitLoadToSessionType
   defaults write "$LOGIN_PLIST" ProgramArguments -array "$C_ENROLMENT" "startTrackerDialog"
   "$C_DIALOG" --loginwindow --title "Welcome to ${"$( defaultRead corpName )":-"The Service Desk"}" --message "Restarting for Application Installation." --timer 60 --position bottom --button1text "Restart Now..."
   shutdown -r now
  fi
 ;;
 process)
  # update LOG_JSON to identify and follow the correct log file.
  plutil -replace displaylog -string "$LOG_FILE" "$LOG_JSON"
  track string message "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE"
  plutil -replace message -string "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE" "$LOG_JSON"

  # finishing setting up admin accounts
  # Add JSS ADMIN
  trackNow "Creating $JSS_NAME Account" \
  secure "'$C_MKUSER' --username $JSS_ADMIN --password '$DEFAULT_PASS' --real-name '$JSS_NAME' --home /private/var/$JSS_ADMIN --hidden userOnly --skip-setup-assistant firstLoginOnly --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes " "Creating username completesetup" \
   file "/private/var/$JSS_ADMIN"
  # Add LAPS ADMIN
  trackNow "Creating $LAPS_NAME Account" \
   secure "'$C_MKUSER' --username $LAPS_ADMIN --password '$DEFAULT_PASS' --real-name '$LAPS_NAME' --home /private/var/$LAPS_ADMIN --hidden userOnly --skip-setup-assistant firstLoginOnly --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes " "Creating username completesetup" \
   file "/private/var/$LAPS_ADMIN"
 
  if [ "$( defaults read "$DEFAULTS_FILE" installs 2>/dev/null )" != "" ]; then
   
   track new "Task List"
   track update status pending
   track update statustext "Loading..."
   track update subtitle "Loading the task list from the config profile."
   # Identify index of first cycling check item, until now each item would retry automatically
   #  immediately for up to 5 time, now we want to switch to trying everything else before retrying,
   #  and keep going until everything is successful, or a specified timeout (at 5 minutes per item?).
   TRACKER_START=$($( jq 'currentitem' ):--1}
   track integer startitem $((TRACKER_START+1))
   
   # Now is a good time to start Self Service in the background
   open -j -a "$SELF_SERVICE"

   # load software installs
   NEW_INDEX=0
   track update status wait
   until [ $NEW_INDEX -eq $( "$( listRead "installs" )" ) ]; do
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
    ((NEW_INDEX++))
   done
   track new "Inventory Update"
   track update command "$C_JAMF recon"
   track update commndtype command
   track update subtitle "jamf recon"
   track update successtype "date"
   track new "Pause for 30 seconds"
   track update command "sleep 30"
   track update commndtype command
   track update subtitle "Pause for 30 seconds before checking again."
   track update successtype "pause"
   
   # Restart dialog (just to make sure it got everything).
   dialog --ontop --timer 15 --title "Reloading..." --message "Reloading the tracking dialog..." --icon none --button1disabled --width 400 --height 150 &
   sleep 2
   echo "quit:" >> "$TRACKER_COMMAND"
   sleep 5
   launchctl kickstart gui/$( id -u $( who | grep -v mbsetupuser | grep -m1 console | cut -d " " -f 1 ) )/"$DEFAULTS_NAME.loginwindow"
   sleep 5
   plutil -replace listitem.$TRACKER_START.statustext -string "Loaded" "$TRACKER_JSON"
   echo "listitem: index: $TRACKER_START, statustext: Loaded" >> "$TRACKER_COMMAND"
   sleep 0.1
   plutil -replace listitem.$TRACKER_START.status -string "success" "$TRACKER_JSON"
   echo "listitem: index: $TRACKER_START, status: success" >> "$TRACKER_COMMAND"
   sleep 0.1
   
   # process software installs
   START_TIME=$( date "+%s" )
   WAIT_TIME=$(($NEW_INDEX*${"$( defaultRead perAPP )":-"5"}*60))
   FINISH_TIME=$(($START_TIME+$WAIT_TIME))
   SUCCESS_COUNT=0
   INFOBOX="**macOS $( sw_vers -productversion )** on  <br>$( scutil --get ComputerName )  <br><br>"
   INFOBOX+="**Started:**  <br>$( date -jr "$START_TIME" "+%d/%m/%Y %H:%M" )  <br><br>"
   INFOBOX+="**Estimated Finish:**  <br>$( date -jr "$FINISH_TIME" "+%d/%m/%Y %H:%M" )  <br><br>"
   INFOBOX+="**Apps to Install:** $NEW_INDEX  <br><br>"
   INFOBOX+='**Installed:** $SUCCESS_COUNT  <br><br>'
   eval "track string infobox '$INFOBOX'"
   FINISHED=false
   COUNT=0
   until $FINISHED; do
    FAILED=false
    track integer currentitem $( jq 'startitem' )
    until [ $( jq 'currentitem' ) -ge $( "$( plutil -extract "listitem" raw -o - "$TRACKER_JSON" )" ) ]; do
     if [ "$( jq 'listitem[.currentitem].success' )" != "success" ]; then
      trackIt "$( jq 'listitem[.currentitem].commandtype' )" \
       "$( jq 'listitem[.currentitem].command' )" \
       "$( jq 'listitem[.currentitem].successtype' )" \
       "$( jq 'listitem[.currentitem].successtest' )" \
       "$( jq 'listitem[.currentitem].successteam' )"
      case "$( jq 'listitem[.currentitem].success' )" in
       success)
        ((SUCCESS_COUNT++))
        eval "track string infobox '$INFOBOX'"
       ;;
       fail)
        FAILED=true
        if [ $COUNT -eq 10 ]; then
         track update commandtype "$( jq 'listitem[.currentitem].backuptype' )"
         track update command "$( jq 'listitem[.currentitem].backupcommand' )"
         case "$( jq 'listitem[.currentitem].subtitletype' )" in
          command)
           track update subtitle "$( jq 'listitem[.currentitem].backupcommand' )"
          ;;
          combine)
           track update subtitle "$( jq 'listitem[.currentitem].suppliedsubtitle' ) - $( jq 'listitem[.currentitem].backupcommand' )"
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
    if ! $FAILED || [ "$( date "+%s" )" -gt $FINISH_TIME ]; then
     $FINISHED=true
    fi
   done
   SUCCESS_COUNT=0
   FAILED_COUNT=0
   track integer currentitem 0
   until [ $( jq 'currentitem' ) -ge $( "$( plutil -extract "listitem" raw -o - "$TRACKER_JSON" )" ) ]; do
    case "$( jq 'listitem[.currentitem].success' )" in
     pending)
      track update success success
     ;&
     success)
      ((SUCCESS_COUNT++))
     ;;
     fail)
      ((FAILED_COUNT++))
      track update success error
     ;;
   done
  fi
  # trigger cleanup
  defaults write "$STARTUP_PLIST" ProgramArguments -array "$C_ENROLMENT" "cleanUp"
 ;;
 cleanUp)
  # A clean up routine
  
  logIt "Removing: $CLEANUP_FILES"
  eval "rm -rf $CLEANUP_FILES"
 ;;
 *)
  # how did this happen
 ;;
esac

