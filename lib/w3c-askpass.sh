#!/bin/sh
# The SUDO_ASKPASS helper of w3c-linux. sudo -A runs it as the invoking user with its own prompt as the only argument and reads the
# password from its stdout; zenity prints what was typed and exits non-zero on Cancel. The command shown comes from W3C_ASKPASS_CMD, which
# nat_apply sets for the one sudo call. exec: the password goes from zenity straight into sudo's pipe; nothing here logs or stores it.
exec zenity --entry --hide-text --title=w3c-linux --width=520 --text="w3c-linux needs your password to run as root: ${W3C_ASKPASS_CMD:-the NAT rule shown before} (the rule shown before) so Warcraft III's LAN test can reach the W3Champions launcher. Nothing else is run." 2> /dev/null
