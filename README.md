# Repo Overview
This repository is the home of a set of bash scripts that enable and configure an enhanced session mode on Linux VMs (Ubuntu, arch) for Hyper-V. You can learn more about this in our [blog post](https://techcommunity.microsoft.com/t5/virtualization/sneak-peek-taking-a-spin-with-enhanced-linux-vms/ba-p/382415).

# How to use the repo
Onboarding instructions for Ubuntu can be found on the [repo wiki](https://github.com/Microsoft/linux-vm-tools/wiki/Onboarding:-Ubuntu).

## Ubuntu and Xubuntu 26.04

Ubuntu 26.04 ships GNOME 50 without an X11 session. Because Hyper-V Enhanced Session Mode through xrdp still requires Xorg, the 26.04 script installs a separate Xfce session. The normal GNOME/Wayland desktop remains installed.

Xubuntu 26.04 already includes Xfce and uses the dedicated `xubuntu/26.04/install.sh` script.

Run inside the Ubuntu VM:

```bash
git clone https://github.com/OldSuns/linux-vm-tools.git
cd linux-vm-tools
sudo ./ubuntu/26.04/install.sh
sudo poweroff
```

For Xubuntu, replace the install command with:

```bash
sudo ./xubuntu/26.04/install.sh
sudo poweroff
```

For a one-line install using a GitHub download proxy in mainland China:

```bash
wget -qO- 'https://gh-proxy.com/https://raw.githubusercontent.com/OldSuns/linux-vm-tools/master/ubuntu/26.04/install.sh' | sudo bash
```

The proxy only accelerates the script download. Package installation still uses the Ubuntu repositories configured on the VM.

After installation completes, fully power off the VM. Then run these commands in an elevated PowerShell terminal on the Hyper-V host. The guest Bash script cannot change these host settings:

```powershell
Set-VMHost -EnableEnhancedSessionMode $true
Set-VM -VMName '<vm-name>' -EnhancedSessionTransportType HvSocket

Get-VMHost | Select-Object EnableEnhancedSessionMode
Get-VM -VMName '<vm-name>' | Select-Object Name, EnhancedSessionTransportType
```

The expected values are `EnableEnhancedSessionMode = True` and `EnhancedSessionTransportType = HvSocket`. Start the VM again and connect with `vmconnect.exe`.

# FAQ
Frequently Asked Questions for this repo can be found on the [repo wiki](https://github.com/Microsoft/linux-vm-tools/wiki/FAQ).

# Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.microsoft.com.

When you submit a pull request, a CLA-bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., label, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.
