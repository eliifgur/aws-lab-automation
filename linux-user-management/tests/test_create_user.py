import os
import shutil
import subprocess
import sys
from unittest.mock import patch

import pytest

# Make create_user.py (one directory up) importable before importing it
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import create_user as cu 


def test_create_user_runs_useradd_and_chpasswd():
    """Test that create_user runs the correct subprocess commands."""
    with patch("create_user.subprocess.run") as run:
        assert cu.create_user("elif", "secretpassword") is True
    run.assert_any_call(["sudo", "useradd", "-m", "elif"], check=True)
    assert run.call_args_list[1].args[0] == ["sudo", "chpasswd"]
    assert run.call_args_list[1].kwargs["input"] == "elif:secretpassword"


def test_create_user_returns_false_on_failure():
    """Test that create_user returns False when subprocess.run raises a CalledProcessError."""
    with patch("create_user.subprocess.run",
               side_effect=subprocess.CalledProcessError(1, "useradd")):
        assert cu.create_user("elif", "secretpassword") is False


def test_main_cancel_does_not_create_user():
    """Test that the main function does not create a user when the user cancels the operation."""
    with patch("builtins.input", side_effect=["elif", "N"]), \
         patch("create_user.getpass.getpass", return_value="secretpassword"), \
         patch("create_user.check_user_exists", return_value=False), \
         patch("create_user.create_user") as create:
        cu.main()
    create.assert_not_called()


def test_main_confirm_creates_user_and_directory():
    """Test that confirming with Y creates the user and the home directory."""
    with patch("builtins.input", side_effect=["elif", "Y"]), \
         patch("create_user.getpass.getpass", return_value="secretpassword"), \
         patch("create_user.check_user_exists", return_value=False), \
         patch("create_user.create_user", return_value=True) as create, \
         patch("create_user.create_directory_for_user") as create_dir:
        cu.main()
    create.assert_called_once_with("elif", "secretpassword")
    create_dir.assert_called_once_with("elif")


@pytest.mark.skipif(shutil.which("getent") is None, reason="Linux only")
def test_unknown_user_does_not_exist():
    """Test that check_user_exists returns False for a user that does not exist."""
    # Uses the real getent — this test catches the check=True crash
    assert cu.check_user_exists("no-such-user-xyz123") is False