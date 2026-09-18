{ options, lib, ... }:
{
  options.selfhost.mail = {
    active = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = options.selfhost.mail.host.isDefined;
      defaultText = lib.literalMD "true once `host` is set";
      description = "Whether outbound mail is configured. Compose against this: a consumer that never sets `selfhost.mail` gets the features that need no SMTP, and nothing asks for a value nobody supplied.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      description = "SMTP server hostname. Setting it is what makes `active` true, so the rest of this block is expected alongside it.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 587;
      description = "SMTP server port";
    };

    from = lib.mkOption {
      type = lib.types.str;
      description = "Sender email address";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "SMTP authentication username";
    };

    tls = lib.mkOption {
      type = lib.types.enum [
        "none"
        "starttls"
        "tls"
      ];
      default = "starttls";
      description = "TLS mode for SMTP connection";
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to file containing the SMTP password (typically a sops secret path). Each consumer reads it as its own service user, so own the file by that user — today Pocket-ID's, the only one that sends mail.";
    };
  };
}
