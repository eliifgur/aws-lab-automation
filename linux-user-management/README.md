# Example name

Creates a new Linux user with a name of your choice, creates a home directory for the user (if one is not automatically created), and ensures that the user owns their home directory.

## What it does

- Uses the subprocess module (or similar) to run Linux commands.
- Checks if the user already exists, and if not, creates it.
- Ensures the user has a home directory (/home/username).
- Sets correct ownership and permissions for the home directory.

## Prerequisites

- a running EC2 instance
- SHH connection to EC2 
- Python3 installed in EC2 

## Usage

```bash
python3 create_user.py
```

## Notes

- Use ls, cat /etc/passwd, and ls -ld /home/username to confirm that everything worked.

