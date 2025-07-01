#!/bin/zsh -f

completeEnrolment="/usr/local/bin/completeEnrolment"
mkdir -p $( dirname $completeEnrolment )
head -n1 "$0" > "$completeEnrolment"
chmod -R 755 $( dirname $completeEnrolment )
chown -R root:wheel $( dirname $completeEnrolment )
tail -n $(($( wc -l "$0" | awk '{ print $1 }' )-$( grep -n -m1 "^exit 0" "$0" | cut -d ':' -f 1 ))) "$0" >> "$completeEnrolment"

exit 0
#
#

# Whose logged in

# The who command method is used as it is the only one that still returns _mbsetupuser as used by
# Setup Assistant, confirming it as the only username logged into the console is the best way to
# identify a ADE/DEP Jamf PreStage Enrollment (after confirming the script was started by Jamf Pro
# with a / in $1).

if [ "$( who | grep console | wc -l )" -gt 1 ]; then
 WHO_LOGGED="$( who | grep -v mbsetupuser | grep -m1 console | cut -d " " -f 1 )"
else
 WHO_LOGGED="$( who | grep -m1 console | cut -d " " -f 1 )"
fi

case $1 in
 /)
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
 atLoginWindow)
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

