import subprocess
import getpass

def check_user_exists(username):
    """Checks if a user already exists in the system."""
    result = subprocess.run(
           ["getent", "passwd", username],
           stdout=subprocess.PIPE,
           stderr=subprocess.PIPE,
           check=False
           )
    return result.returncode == 0

def create_user(username, password):
    """Creates a new user with the given username and password."""
    try:
        subprocess.run(
            ["sudo", "useradd", "-m", username],
            check=True
        )

        subprocess.run(
            ["sudo", "chpasswd"],
            input=f"{username}:{password}",
            text=True,
            check=True
        )

        print(f"User {username} created successfully!")
        return True

    except subprocess.CalledProcessError as e:
        print(f"Failed to create user {username}: {e}")
        return False

def create_directory_for_user(username):
    """Creates a directory for the user in /home/username with appropriate permissions."""
    directory_path = f"/home/{username}"
    directory_exists = subprocess.run(["test", "-d", directory_path],check=False)
    if directory_exists.returncode == 0:
        print(f"Directory {directory_path} already exists.")
        return
    try:
        subprocess.run(["sudo", "mkdir", "-p", directory_path], check=True)
        subprocess.run(["sudo", "chown", f"{username}:{username}", directory_path], check=True)
        subprocess.run(["sudo", "chmod", "700", directory_path], check=True)
        print(f"Directory {directory_path} created successfully.")
    except Exception as e:
        print(f"Failed to create directory {directory_path}. Error: {e}")

def main():
    """Main function to create a new user."""
    confirmation = "N"
    while True:
        username = input("Enter username: ")

        if check_user_exists(username):
            print(f"User '{username}' already exists. Please choose a different username.")
            continue
        else:
            break

    password = getpass.getpass("Enter password: ")

    while confirmation.upper() != "Y":
        confirmation = input(f"Are you sure you want to create the user '{username}'? (Y/N): ")
        if confirmation.upper() == "Y":
            if create_user(username, password):
                create_directory_for_user(username)
                break
        if confirmation.upper() == "N":
            print("User creation cancelled.")
            return
        else:
            print("Invalid input. Please enter 'Y' or 'N'.")


if __name__ == "__main__":
    main()
