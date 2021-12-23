#!/bin/sh

# my_snapshots/                 your folder to store the snapshots in
# |- rsync_snapshot.sh          this script
# |- exclude.list               list of files to be excluded
# `- snapshots/                 folder generated by script to store snapshots
#    |- YYMMDD-hhmmss/          snapshot folder
#    |  |- system/              snapshot of the root system
#    |  |- exclude.list         excluded files for this snapshot
#    |  |- rsync.log            rsync log for this snapshot
#    |  `- script.sh            script used for this snapshot
#    `- last -> YYMMDD-hhmmss/  links to last snapshot

# check if running as root
if [ $UID -ne 0 ]; then
	echo "run as root"
	exit 1
fi

## save path
SAVE_PATH=$1
## no param assume current directory
if [[ -z $SAVE_PATH ]]; then
	SAVE_PATH="."
elif [[ ! -d $SAVE_PATH ]]; then
	echo "directory not found"
	exit 1
fi

# snapshot_s_ path
SNAPSHOTS_FOLDER=$SAVE_PATH/snapshots
if [[ ! -d $SNAPSHOTS_FOLDER ]]; then
	echo "Creating $SNAPSHOTS_FOLDER"
	mkdir $SNAPSHOTS_FOLDER
fi

# exclude file
MASTER_EXCLUDE_FILE=$SAVE_PATH/exclude.list
## exclude.list not found, probably first time running script
if [[ ! -f $MASTER_EXCLUDE_FILE ]]; then
	# create template exclude file
	echo "/dev/*
/proc/*
/sys/*
/run/*
/tmp/*
/mnt/*
/lost+found

/var/run/*
/var/lock/*
/var/tmp/*

/home/*/.cache/*" > $MASTER_EXCLUDE_FILE

	echo "Creating '$MASTER_EXCLUDE_FILE' with a default exclude template,"
	echo "Please review/modify it and run script again"
	exit
fi

# snapshot path
SNAPSHOT_PATH=$SNAPSHOTS_FOLDER/$(date +'%y%m%d-%H%M%S')
mkdir "$SNAPSHOT_PATH"

# last snapshot
SNAPSHOT_LAST=$SNAPSHOTS_FOLDER/last

# snapshot backup location
SNAPSHOT_LOCATION=$SNAPSHOT_PATH/system
mkdir "$SNAPSHOT_LOCATION"

# snapshot log
SNAPSHOT_LOG=$SNAPSHOT_PATH/rsync.log

# copy exclude file to snapshot folder as it may change over time (for records)
EXCLUDE_FILE=$SNAPSHOT_PATH/exclude.list
cp "$MASTER_EXCLUDE_FILE" "$EXCLUDE_FILE"

# copy this script to snapshot folder as it may also change in future
SCRIPT_FILE=$SNAPSHOT_PATH/script.sh
cp "$0" "$SCRIPT_FILE"


function interruptHandler() {
	echo "Operation canceled, deleting partial snapshot..."
	rm -rf "$SNAPSHOT_PATH"
	echo "Partial snapshot deleted, exiting."
	exit
}
trap interruptHandler SIGINT


## rsync paramaters
OPT="-aAXH -vh" # archive, ACLs, xattrs, hard links, verbose, human sizes
# if first snapshot dosent exist dont include --link-dest
[[ -d $SNAPSHOT_LAST ]] && LINK="--link-dest=$(realpath $SNAPSHOT_LAST)/system/"
SRC="/" # root filesystem is source of snapshot
EXCLUDE="--exclude-from=$EXCLUDE_FILE"

## rsync command
# take snapshot with rsync saving stdout and stderr to $SNAPSHOT_LOG
rsync $OPT $LINK $EXCLUDE $SRC $SNAPSHOT_LOCATION 2>&1 | tee $SNAPSHOT_LOG

# update latest snapshot pointer
rm -f $SNAPSHOT_LAST
ln -s $(basename $SNAPSHOT_PATH) $SNAPSHOT_LAST

echo "Successfully created snapshot."