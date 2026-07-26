[Português](README.md) | **English**

# Support the project

If you like the results provided by this application, consider making a donation of any amount via Pix to `jorgezarpon@msn.com`.

# Turbo-Decky-
SteamOS optimization utility

The application is intended to work on any device running SteamOS and on Arch Linux-based distributions.

# What is Turbo Decky?

Turbo Decky is a utility designed to improve SteamOS performance on devices such as the Steam Deck, making the system faster, smoother, and more stable, especially while gaming.

It automatically adjusts the system to make better use of memory, processor resources, storage, and the graphics processor.

These optimizations are safe, reversible, and intended for users who want better performance without having to understand advanced system configuration.

---

# What does it do?

Turbo Decky applies several internal improvements, including:

- Faster game loading and fewer micro-stutters.
- Improved RAM management.
- ZSWAP support to reduce performance drops when RAM is under pressure.
- Storage read and write adjustments for a more responsive system.
- AMDGPU behavior optimizations.
- Disabling unnecessary system services that consume resources.
- System limit adjustments to reduce gaming bottlenecks.
- Optional installation of a custom kernel for improved performance.

Turbo Decky can install the Charcoal-vulcano custom kernel.

This is a customized version of the kernel developed by V10lator.

**Attention:** The kernel is currently compatible only with SteamOS version `3.8.*` on the stable channel.

Original Charcoal kernel repository: https://github.com/V10lator/linux-charcoal

Everything is automated. Select an option and let the application complete the process.

# How to install and run

## Recommended method: AppImage

1. On the Steam Deck, switch to **Desktop Mode**.
2. Download the latest file:

   **[Download TurboDecky-x86_64.AppImage](https://github.com/zarpon/Turbo-Decky-/releases/download/Latest/TurboDecky-x86_64.AppImage)**

3. In Dolphin, right-click the file, open **Properties > Permissions**, and enable **Is executable**.
4. Open the AppImage by double-clicking it.
5. Select the desired optimization. During each procedure, a progress window shows the current stage and completion percentage; if something fails, the interrupted stage is identified. Administrative authentication is requested only when the selected action needs to modify the system.
6. Restart the Steam Deck after applying or reverting optimizations that change memory settings, GRUB, or the kernel.

### Charcoal kernel installation

On the first Charcoal kernel installation, a dedicated confirmation is always shown, explaining that the SteamOS stock kernel must be removed before installation; keeping it can make the installation fail. The application checks installed packages, removes every detected `linux-neptune*` package only after confirmation, and installs Charcoal only after validating the downloaded archive and each package. Updates also remove any remaining stock package before installing the new packages.

## Install from the terminal

```bash
curl --fail --location --retry 3 \
  -o TurboDecky-x86_64.AppImage \
  https://github.com/zarpon/Turbo-Decky-/releases/download/Latest/TurboDecky-x86_64.AppImage
chmod +x TurboDecky-x86_64.AppImage
./TurboDecky-x86_64.AppImage
```

## Verify download integrity

```bash
curl --fail --location --retry 3 \
  -O https://github.com/zarpon/Turbo-Decky-/releases/download/Latest/TurboDecky-x86_64.AppImage.sha256
sha256sum -c TurboDecky-x86_64.AppImage.sha256
```

The repository workflow automatically rebuilds, tests, and publishes the AppImage and its SHA-256 file to the `Latest` Release after approved changes reach the `main` branch.

## Persistence after reboot

The applied settings remain persistent across a normal reboot:

- sysctl settings in `/etc/sysctl.d/99-turbodecky.conf`;
- THP, KSM, and MGLRU settings in `/etc/tmpfiles.d/99-turbodecky-memory.conf`;
- ZRAM settings in `/etc/systemd/zram-generator.conf.d/00-turbodecky.conf`;
- ZSWAP and kernel parameters in `/etc/default/grub`;
- the ZSWAP swapfile in `/etc/fstab`;
- udev rules, limits, environment variables, and systemd service states;
- SCX LAVD and `fstrim.timer` when enabled.

A SteamOS update may replace settings, packages, or the kernel and require the optimizations to be applied again. Reversion restores the snapshot captured before the first application. Kernel restoration remains a separate action.

# Acknowledgements

Thanks to the entire Linux community, especially projects and developers such as sdweak and CryoUtilities, which were major inspirations for this project.

Special thanks to V10lator for developing the custom kernel for the Steam Deck.
