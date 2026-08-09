# storage.mounts.smb (eval-only): CIFS mounts derive automounts, access groups, dependent-service guards, and
# mount retry drop-ins. No VM: a real mount needs a live SMB server; this covers pure config generation.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  base = {
    enable = true;
    hostname = "192.168.1.10";
    credentialsPath = "/run/secrets/smb";
  };

  cfg = evalConfig {
    selfhost = {
      storage.mounts.smb = base // {
        shares = {
          media = {
            gid = 5001;
          };
          photos = {
            gid = 5002;
          };
        };
      };
      # A registered service that needs the media mount makes it a "dependent" share.
      services.gallery = {
        port = 8080;
        ingress.enable = false;
        storage.mounts = [ "media" ];
      };
    };
  };

  fs = cfg.fileSystems;
  mediaOpts = fs."/mnt/homelab-media".options;
  photosOpts = fs."/mnt/homelab-photos".options;
  gallery = cfg.systemd.services.gallery;
  mediaMountUnit = cfg.systemd.units."mnt-homelab\\x2dmedia.mount";

  collide = evalConfig {
    selfhost.storage.mounts.smb = base // {
      shares = {
        media = {
          gid = 5001;
        };
        photos = {
          gid = 5001;
        }; # duplicate gid
      };
    };
  };
  collisionFires = lib.any (a: !a.assertion && lib.hasInfix "duplicate gids" a.message) collide.assertions;
in
assert lib.assertMsg (cfg.users.groups.homelab-media.gid == 5001) "media mount group not created with its gid";
assert lib.assertMsg (fs."/mnt/homelab-media".device == "//192.168.1.10/media") "wrong CIFS device for media";
assert lib.assertMsg (fs."/mnt/homelab-media".fsType == "cifs") "media mount is not cifs";
assert lib.assertMsg (lib.elem "credentials=/run/secrets/smb" mediaOpts) "credentials mount option missing";
assert lib.assertMsg (lib.elem "nofail" mediaOpts) "dependent share should not block boot";
assert lib.assertMsg (lib.elem "x-systemd.automount" mediaOpts) "dependent share should automount";
assert lib.assertMsg (lib.elem "x-systemd.automount" photosOpts) "independent share should automount";
assert lib.assertMsg (!lib.elem "noauto" photosOpts) "noauto is redundant with automount";
assert lib.assertMsg (lib.elem "mnt-homelab\\x2dmedia.automount" gallery.requires)
  "service should require the automount guard";
assert lib.assertMsg (lib.elem "mnt-homelab\\x2dmedia.automount" gallery.after)
  "service should start after the automount guard";
assert lib.assertMsg ((gallery.serviceConfig.Restart or null) == null) "storage must not set service restart policy";
assert lib.assertMsg (mediaMountUnit.overrideStrategy == "asDropin") "mount retry policy should be a drop-in";
assert lib.assertMsg (lib.hasInfix "StartLimitIntervalSec=0" mediaMountUnit.text)
  "mount attempts should not be rate limited";
assert lib.assertMsg collisionFires "duplicate-gid assertion did not fire";
pkgs.runCommand "selfhost-smb-eval" { } "touch $out"
