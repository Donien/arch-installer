#!/usr/bin/bash


### This script is meant to be run after all partitions are already mounted for an installation of Archlinux
### This script only deals with 1) encryption (LUKS), 2) LVM and 3) uefi vs. bios
### RUN AT OWN RISK!

### What the partitioning might look like
### vda               254:0    0    40G  0 disk
### ├─vda1            254:1    0   512M  0 part  /mnt/boot/efi
### ├─vda2            254:2    0   800M  0 part  /mnt/boot
### └─vda3            254:3    0  38.7G  0 part
###   └─crypt_lvm     252:0    0  38.7G  0 crypt
###     ├─system-swap 252:1    0     4G  0 lvm   [SWAP]
###     ├─system-root 252:2    0    16G  0 lvm   /mnt
###     └─system-home 252:3    0  18.7G  0 lvm   /mnt/home


# Colors
c_reset='\033[0m'
c_red='\033[0;31m'
c_green='\033[0;32m'
c_yellow='\033[0;33m'



check_mount () {
    findmnt /mnt &> /dev/null
    if [ $? -eq 1 ];then
        echo "Nothing is mounted at /mnt"
        return 1
    fi
    return 0
}

ask_crypt_device () {
    root_dev=$(findmnt /mnt --output SOURCE --noheadings)
    while true
    do
        read -e -p "Path to your encrypted partition (leave empty for no encryption): " crypt_dev
        if [[ -z $( echo -n $crypt_dev) ]];then
            echo NOPE
            return
        fi
        blkid -t TYPE=crypto_LUKS $crypt_dev &> /dev/null
        if [[ $? -gt 0 ]];then
            echo "$crypt_dev is not a LUKS device!" 
            continue
        fi
        crypt_uuid=$(blkid -t TYPE=crypto_LUKS $crypt_dev --output export | grep "^UUID" | cut -d '=' -f 2)
        break
    done
}

ask_username () {
    read -e -p "Name of your new user: " new_user
    new_user=$(echo "$new_user" | tr '[:upper:]' '[:lower:]')
    while true
    do
        echo -n "Password: "
        read -s new_user_pwd
        echo
        echo -n "Confirm password: "
        read -s new_user_pwd_tmp
        echo
        if [[ $new_user_pwd != $new_user_pwd_tmp ]];then
            echo -e "$c_red""Passwords don't match!"$c_reset" Try again..."
        else
            break
        fi
    done
    if [[ $new_user_pwd == "" ]];then
        echo -e "$c_yellow""Empty password detected!$c_reset"
        echo -e "$c_yellow""Using default password '123'$c_reset"
        echo -e "$c_yellow""Make sure to set a password manually later...$c_reset"
        new_user_pwd="123"
    fi
}

ask_host_name () {
    read -e -p "Choose a hostname for your system: " host_name
    host_name=$(echo "$host_name" | tr '[:upper:]' '[:lower:]')
}

ask_keymap () {
    while true
    do
        read -e -p "Choose a keymap for your system ('l' for list): " keymap
        if [[ $keymap =~ ^[l]$ ]];then
            localectl list-keymaps
        else
            loadkeys $keymap
            if [[ $? -gt 0 ]];then
                echo "Keymap $keymap could not be found."
            else
                break
            fi
       fi
    done
}

ask_grub_device () {
    efivar --list &> /dev/null
    if [[ $? -eq 0 ]];then
        grub_command="grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"
    else
        echo "BIOS detected."
        while true
        do
            read -e -p "Please choose a device to install GRUB onto: " grub_device
            if [[ -z $(blkid $grub_device --output export | grep PTTYPE | cut -d '=' -f 2) ]];then
                echo "Please choose a physical disk."
            else
                grub_command="grub-install --target=i386-pc $grub_device"
                break
            fi
        done
    fi
}

install_packages () {
    pacstrap_pkgs="
    base
    base-devel
    linux
    linux-firmware
    networkmanager
    grub
    efibootmgr
    lvm2
    "
    pacstrap /mnt --needed --noconfirm $pacstrap_pkgs
}

set_fstab () {
    genfstab -U /mnt >> /mnt/etc/fstab
}

set_locales () {
    sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen
}

set_keymap () {
    echo "KEYMAP=$keymap" > /mnt/etc/vconsole.conf
}

set_host_name () {
    echo -e "127.0.0.1\tlocalhost" >> /mnt/etc/hosts
    echo -e "::1\tlocalhost" >> /mnt/etc/hosts
    echo -e "127.0.1.1	$host_name.localdomain\t$host_name" >> /mnt/etc/hosts
    
    echo "$host_name" > /mnt/etc/hostname
}

set_mkinitcpio_hooks () {
    mkinitcpio_hooks="
    base
    udev
    autodetect
    modconf
    keyboard
    keymap
    consolefont
    block
    encrypt
    lvm2
    filesystems
    resume
    fsck
    "
    sed -i -E "s/(^HOOKS=\()(.*)(\))/\1$(echo $mkinitcpio_hooks)\3/" /mnt/etc/mkinitcpio.conf
    arch-chroot /mnt bash -c "mkinitcpio -P"
}

configure_grub () {
    if [ -z "$crypt_uuid" ];then
        grub_cmdline="root=$root_dev"
    else
        grub_cmdline="cryptdevice=UUID=$crypt_uuid:$(basename $root_dev) root=$root_dev"
    fi
    sed -i -E "s|(^GRUB_CMDLINE_LINUX=.)(.*)(.)|\1$grub_cmdline\3|" /mnt/etc/default/grub
}

install_grub () {
    configure_grub 
    arch-chroot /mnt bash -c "$grub_command"
    arch-chroot /mnt bash -c "grub-mkconfig -o /boot/grub/grub.cfg"
}

create_user () {
    arch-chroot /mnt bash -c "useradd -m $new_user"
    arch-chroot /mnt bash -c "echo $new_user:$new_user_pwd | chpasswd"
    arch-chroot /mnt bash -c "usermod -a -G wheel $new_user"
}

allow_wheel () {
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers
}

enable_networking () {
    arch-chroot /mnt bash -c "systemctl enable NetworkManager"
}

unmount_mnt () {
    read -e -p "Unmount /mnt? [y/N] "
    echo
    if [[ $REPLY =~ ^[Yy] ]];then
        umount -R /mnt
    fi
}

ask_confirmation () {
    echo "=================================="
    echo "The following values would be used"
    echo "=================================="

    echo -e "Encrypted disk   : $c_green""$crypt_dev""$c_reset"
    echo -e "Root device ('/'): $c_green""$root_dev""$c_reset"
    echo -e "New user name    : $c_green""$new_user""$c_reset"
    echo -e "New hostname     : $c_green""$host_name""$c_reset"
    echo -e "Keymap           : $c_green""$keymap""$c_reset"
    echo -e "Grub command     : $c_green""$grub_command""$c_reset"

    read -p "Is this information correct? (Type 'YES') " 
    echo
    if [[ $REPLY =~ ^YES$ ]];then
        echo "THE SCRIPT WILL BE RUN!"
        echo "Continuing in..."
        for x in {10..1}
        do
            echo $x
            sleep 1
        done
        return 0
    fi
    return 1
}

# main
check_mount || exit 1
ask_crypt_device
ask_username
ask_host_name
ask_keymap
ask_grub_device

ask_confirmation
if [[ $? -eq 0 ]];then
    install_packages
    set_fstab
    set_locales
    set_keymap 
    set_host_name
    set_mkinitcpio_hooks
    install_grub
    create_user
    allow_wheel 
    enable_networking 
    unmount_mnt
else
    echo "Aborting script"
fi
exit 0
