# bashcup - A backup bash script

A simple backup script written in bash to back-up databases and directories.

## Features

* Backup MySQL databases and directories of multiple hosts
* Rotate the backups and keep a defined amount of daily, weekly, monthly,
  and yearly backups
* JSON configuration for hosts and credentials (MySQL)
* Monitoring capabilities (e.g. with Nagios) by listing the age of the most
  current backup
* Logging to syslog

## Setup

Install [jq (JSON command line processor)](https://stedolan.github.io/jq/download/):
```bash
sudo apt install jq
```

To prevent the backup process running twice, files are created in
the /var/run directory. Create the directory and give permission to the user
running the backup:
```bash
sudo mkdir /var/run/backup-sh
chown backup-user:backup-user /var/run/backup-sh
```

## Configuration

Create a [configuration](config.example.json) and a [secret-file](backup-secrets.example.json) to use the backup bash script.

Example configuration `config.json`:
```json
{
  "BACKUP_DIR": "/mnt/volume_backup",
  "hosts": {
    "virtual-host-01": {
      "hostname": "vh01.your-domain.com",
      "databases": {
        "example_production": {
          "ssh_user": "ssh-user",
          "extra_opts": "--no-tablespaces"
        },
        "example_staging": {
          "ssh_user": "ssh-user-staging"
        }
      }
    },
    "virtual-host-02": {
      "hostname": "vh02.your-domain.com",
      "databases": {
        "wordpress": {
          "ssh_user": "wpssh-user"
        }
      },
      "files": {
        "logs_and_config": {
          "ssh_user": "wpssh-user",
          "base_dir": "/var/www/wpdir",
          "directories": [
            "config/",
            "app/log/",
            "another/config/dir/"
          ]
        }
      }
    }
  }
}
```

Example secrets file `.backup-secrets.json`:
```json
{
  "virtual-host-01": {
    "databases": {
      "example_production": {
        "user": "ex-prod-user",
        "password": "PasswordForExProd"
      },
      "example_staging": {
        "user": "ex-stag-user",
        "password": "PasswordForExStag"
      }
    }
  },
  "virtual-host-02": {
    "databases": {
      "wordpress": {
        "user": "wp-user",
        "password": "PasswordForWPUser"
      }
    }
  }
}
```

Secure the file by the following permissions:
```bash
chmod 600 .backup-secrets.json
```

## Usage

To execute the bash script, the configuration and the secrets file have to be set
by the command line parameters `-c|--config-json` and `-s|--secret-json`:

```bash
./bin/backup.sh -c config.json -s .backup-secrets.json <command>
```

### Help

Run `./backup.sh -h` shows the help with the available commands:

```txt
  backup.sh [options] [command]
  backup.sh [optoins] backup <host>
  backup.sh [options] rotate
  backup.sh [options] list
  backup.sh [options] check

Backup or rotate databases and files to a specific folder.

Commands:
  backup <host>       backup database and files of a given host
  rotate              rotate all backup files (daily, weekly, monthly, yearly)
  list                list avaiable backups per host with age (useful for monitoring)
  check               check access for the configuration

Options:
  -c, --config-json   configuration of hosts, files, databases to backup
  -s, --secret-json   credentials for database dumps
  -v, --verbose       print output
  -h, --help          display this
```

### Cronjobs

The following cronjobs define when to back-up the hosts and rotate all the backups:

```bash
0 2 * * * /home/backup-user/bin/backup.sh -v -c /home/backup-user/config.json -s /home/backup-user/.backup-secrets.json backup virtual-host-01
0 3 * * * /home/backup-user/bin/backup.sh -v -c /home/backup-user/config.json -s /home/backup-user/.backup-secrets.json backup virtual-host-02
0 4 * * * /home/backup-user/bin/backup.sh -v -c /home/backup-user/config.json -s /home/backup-user/.backup-secrets.json rotate
```

## References

* If you're looking for something similar which creates incremental file backups,
  refer to the [backup script of Perfacilis](https://www.perfacilis.com/blog/systeembeheer/linux/rsync-daily-weekly-monthly-incremental-back-ups.html).
