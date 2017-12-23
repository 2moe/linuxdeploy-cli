#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

[ -n "${SUITE}" ] || SUITE="25"

if [ -z "${ARCH}" ]
then
    case "$(get_platform)" in
    x86) ARCH="i386" ;;
    x86_64) ARCH="x86_64" ;;
    arm) ARCH="armhfp" ;;
    arm_64) ARCH="aarch64" ;;
    esac
fi

[ -n "${SOURCE_PATH}" ] || SOURCE_PATH="http://dl.fedoraproject.org/pub/"

dnf_install()
{
    local packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        chroot_exec -u root dnf --nogpgcheck -y install ${packages}
        chroot_exec -u root dnf clean packages
    exit 0)
    return $?
}

yum_repository()
{
    find "${CHROOT_DIR}/etc/yum.repos.d/" -name '*.repo' | while read f; do sed -i 's/^enabled=.*/enabled=0/g' "${f}"; done
    local repo_file="${CHROOT_DIR}/etc/yum.repos.d/fedora-${SUITE}-${ARCH}.repo"
    if [ "${ARCH}" = "aarch64" ]
    then local repo_url="${SOURCE_PATH%/}/fedora-secondary/releases/${SUITE}/Everything/${ARCH}/os"
    else local repo_url="${SOURCE_PATH%/}/fedora/linux/releases/${SUITE}/Everything/${ARCH}/os"
    fi
    echo "[fedora-${SUITE}-${ARCH}]" > "${repo_file}"
    echo "name=Fedora ${SUITE} - ${ARCH}" >> "${repo_file}"
    echo "failovermethod=priority" >> "${repo_file}"
    echo "baseurl=${repo_url}" >> "${repo_file}"
    echo "enabled=1" >> "${repo_file}"
    echo "metadata_expire=7d" >> "${repo_file}"
    echo "gpgcheck=0" >> "${repo_file}"
    chmod 644 "${repo_file}"
}

do_install()
{
    is_archive "${SOURCE_PATH}" && return 0

    msg ":: Installing ${COMPONENT} ... "

    local basic_packages="filesystem setup audit-libs basesystem bash bash-completion bzip2-libs ca-certificates chkconfig coreutils cpio cracklib cracklib-dicts crypto-policies cryptsetup-libs curl cyrus-sasl-lib dbus dbus-libs deltarpm device-mapper-libs dnf dnf-conf elfutils-libelf elfutils-libs expat fedora-release fedora-repos file-libs gawk gdbm glib2 glibc glibc-common glibc-locale-source gmp gnupg2 gnutls gpgme grep gzip hawkey info iptables-libs keyutils-libs kmod-libs krb5-libs libacl libarchive libassuan libattr libblkid libcap libcap-ng libcom_err libcomps libcrypt libcurl libdb libdb-utils libdnf libffi libgcc libgcrypt libgpg-error libidn libidn2 libmetalink libmount libnghttp2 libpcap libpsl libpwquality librepo libreport-filesystem libseccomp libselinux libselinux-utils libsemanage libsepol libsigsegv libsmartcols libsolv libssh2 libtasn1 libunistring libutempter libuuid libverto libxml2 libzstd lua-libs lz4 lz4-libs lzo mpfr ncurses ncurses-base ncurses-libs nettle nspr nss nss-softokn nss-softokn-freebl nss-sysinit nss-tools nss-util openldap openssl-libs p11-kit p11-kit-trust pam pcre pcre2 popt python3 python3-dnf python3-gpg python3-hawkey python3-iniparse python3-libcomps python3-librepo python3-libs python3-pip python3-pygpgme python3-rpm python3-setuptools python3-six qrencode-libs readline rpm rpm-build-libs rpm-libs rpm-plugin-selinux rpm-plugin-systemd-inhibit sed selinux-policy shadow-utils sqlite-libs sudo system-python system-python-libs systemd systemd-libs tzdata ustr util-linux vim-minimal which xz-libs zlib"

    if [ "${ARCH}" = "aarch64" ]
    then local repo_url="${SOURCE_PATH%/}/fedora-secondary/releases/${SUITE}/Everything/${ARCH}/os"
    else local repo_url="${SOURCE_PATH%/}/fedora/linux/releases/${SUITE}/Everything/${ARCH}/os"
    fi

    msg "URL: ${repo_url}"

    msg -n "Preparing for deployment ... "
    tar xzf "${COMPONENT_DIR}/filesystem.tgz" -C "${CHROOT_DIR}"
    is_ok "fail" "done" || return 1

    msg -n "Retrieving packages list ... "
    local pkg_list="${CHROOT_DIR}/tmp/packages.list"
    (set -e
        repodata=$(wget -q -O - "${repo_url}/repodata/repomd.xml" | sed -n '/<location / s/^.*<location [^>]*href="\([^\"]*\-primary\.xml\.gz\)".*$/\1/p')
        [ -z "${repodata}" ] && exit 1
        wget -q -O - "${repo_url}/${repodata}" | gzip -dc | sed -n '/<location / s/^.*<location [^>]*href="\([^\"]*\)".*$/\1/p' > "${pkg_list}"
    exit 0)
    is_ok "fail" "done" || return 1

    msg "Retrieving base packages: "
    local package i pkg_url pkg_file pkg_arch
    case "${ARCH}" in
    i386) pkg_arch="-e i686 -e noarch" ;;
    x86_64) pkg_arch="-e x86_64 -e noarch" ;;
    armhfp) pkg_arch="-e armv7hl -e noarch" ;;
    aarch64) pkg_arch="-e aarch64 -e noarch" ;;
    esac
    for package in ${basic_packages}; do
        msg -n "${package} ... "
        pkg_url=$(grep -e "^.*/${package}-[0-9r][0-9\.\-].*rpm$" "${pkg_list}" | grep -m1 ${pkg_arch})
        test "${pkg_url}"
        is_ok "skip" || continue
        pkg_file="${pkg_url##*/}"
        # download
        for i in 1 2 3
        do
            wget -q -c -O "${CHROOT_DIR}/tmp/${pkg_file}" "${repo_url}/${pkg_url}" && break
            sleep 30s
        done
        [ "${package}" = "filesystem" ] && { msg "done"; continue; }
        # unpack
        (cd "${CHROOT_DIR}"; rpm2cpio "./tmp/${pkg_file}" | cpio -idmu >/dev/null)
        is_ok "fail" "done" || return 1
    done

    component_exec core/emulator

    msg "Installing base packages ... "
    chroot_exec /bin/rpm -i --force --nosignature --nodeps /tmp/*.rpm
    is_ok || return 1

    msg -n "Clearing cache ... "
    rm -rf "${CHROOT_DIR}"/tmp/*
    is_ok "skip" "done"

    component_exec core/mnt core/net

    msg -n "Updating repository ... "
    yum_repository
    is_ok "fail" "done"

    msg "Installing minimal environment: "
    dnf_install @minimal-environment --exclude filesystem,openssh-server
    is_ok || return 1

    return 0
}

do_help()
{
cat <<EOF
   --arch="${ARCH}"
     Architecture of Linux distribution, supported "armhfp", "aarch64", "i386" and "x86_64".

   --suite="${SUITE}"
     Version of Linux distribution, supported versions "25", "26" and "27".

   --source-path="${SOURCE_PATH}"
     Installation source, can specify address of the repository or path to the rootfs archive.

EOF
}
