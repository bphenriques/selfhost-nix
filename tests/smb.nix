# storage.smb (eval-only): CIFS mounts derive fileSystems entries + per-share access groups; a share with
# dependent units boot-mounts with nofail while an independent share lazy-automounts, and duplicate gids
# trip the assertion. No VM — a real mount needs a live SMB server; this covers the pure config generation.
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
      storage.smb = base // {
        mounts = {
          media = {
            gid = 5001;
          }; # a dependent service (below) → boot-mount with nofail
          photos = {
            gid = 5002;
          }; # no dependents → lazy automount
        };
      };
      # A registered service that needs the media mount makes it a "dependent" share.
      services.gallery = {
        port = 8080;
        ingress.enable = false;
        storage.smb = [ "media" ];
      };
    };
  };

  fs = cfg.fileSystems;
  mediaOpts = fs."/mnt/homelab-media".options;
  photosOpts = fs."/mnt/homelab-photos".options;

  collide = evalConfig {
    selfhost.storage.smb = base // {
      mounts = {
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
assert lib.assertMsg (lib.elem "nofail" mediaOpts) "dependent share should boot-mount with nofail";
assert lib.assertMsg (!lib.elem "x-systemd.automount" mediaOpts) "dependent share must not lazy-automount";
assert lib.assertMsg (lib.elem "x-systemd.automount" photosOpts) "independent share should lazy-automount";
assert lib.assertMsg (lib.elem "noauto" photosOpts) "independent share should be noauto";
assert lib.assertMsg collisionFires "duplicate-gid assertion did not fire";
pkgs.runCommand "selfhost-smb-eval" { } "touch $out"
