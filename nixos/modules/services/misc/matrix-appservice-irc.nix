{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.matrix-appservice-irc;

  pkg = pkgs.matrix-appservice-irc;
  bin = "${pkg}/bin/matrix-appservice-irc";

  configFile = pkgs.runCommandNoCC "matrix-appservice-irc.yml" {
    # Because this program will be run at build time, we need `nativeBuildInputs`
    nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ps.jsonschema ])) ];

    config = builtins.toJSON cfg.settings;
    passAsFile = [ "config" ];
  } ''
    # The schema is given as yaml, we need to convert it to json
    python -c 'import json; import yaml; import sys; json.dump(yaml.safe_load(sys.stdin), sys.stdout)' \
      < ${pkg}/lib/node_modules/matrix-appservice-irc/config.schema.yml \
      > config.schema.json
    python -m jsonschema config.schema.json -i $configPath
    cp "$configPath" "$out"
  '';
  registrationFile = "/var/lib/matrix-appservice-irc/registration.yml";
in {
  options.services.matrix-appservice-irc = with types; {
    enable = mkEnableOption "the Matrix/IRC bridge";

    port = mkOption {
      type = port;
      description = "The port to listen on";
      default = 8009;
    };

    needBindingCap = mkOption {
      type = bool;
      description = "Whether the daemon needs to bind to ports below 1024 (e.g. for the ident service)";
      default = false;
    };

    passwordKeyLength = mkOption {
      type = ints.unsigned;
      description = "Length of the key to encrypt IRC passwords";
      default = 4096;
      example = 8192;
    };

    registrationUrl = mkOption {
      type = str;
      description = "The URL where the application service is listening for HS requests";
      example = "http://localhost:8009";
    };

    localpart = mkOption {
      type = str;
      description = "The user_id localpart to assign to the AS";
      default = "appservice-irc";
    };

    settings = mkOption {
      description = ''Configuration for the appservice, see <link xlink:href="https://github.com/matrix-org/matrix-appservice-irc/blob/${pkgs.matrix-appservice-irc.version}/config.sample.yaml"/> for supported values'';
      default = {};
      type = submodule {
        freeformType = unspecified;

        options = {
          homeserver = mkOption {
            description = "Homeserver configuration";
            default = {};
            type = submodule {
              options = {
                url = mkOption {
                  type = str;
                  description = "The URL to the home server for client-server API calls";
                };

                domain = mkOption {
                  type = str;
                  description = ''The 'domain' part for user IDs on this home server. Usually (but not always) is the "domain name" part of the HS URL.'';
                };
              };
            };
          };

          database = mkOption {
            default = {};
            description = "Configuration for the database";
            type = submodule {
              freeformType = unspecified;

              options = {
                engine = mkOption {
                  type = str;
                  description = "Which database engine to use";
                  default = "nedb";
                };

                connectionString = mkOption {
                  type = str;
                  description = "The database connection string";
                  default = "nedb://var/lib/matrix-appservice-irc/data";
                };
              };
            };
          };

          ircService = mkOption {
            default = {};
            description = "IRC bridge configuration";
            type = submodule {
              freeformType = unspecified;

              options = {
                passwordEncryptionKeyPath = mkOption {
                  type = str;
                  description = "Location of the key with which IRC passwords are encrypted for storage. Will be generated on first run if not present.";
                  default = "/var/lib/matrix-appservice-irc/passkey.pem";
                };

                servers = mkOption {
                  type = submodule { freeformType = unspecified; };
                  description = "IRC servers to connect to";
                };
              };
            };
          };
        };
      };
    };
  };
  config = mkIf cfg.enable {
    systemd.services.matrix-appservice-irc = {
      description = "Matrix-IRC bridge";
      before = [ "matrix-synapse.service" ]; # So the registration can be used by Synapse
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        umask 077

        # Generate key for crypting passwords
        if ! [ -f "${cfg.settings.ircService.passwordEncryptionKeyPath}" ]; then
          ${pkgs.openssl}/bin/openssl genpkey -out "${cfg.settings.ircService.passwordEncryptionKeyPath}" -outform PEM -algorithm RSA -pkeyopt "rsa_keygen_bits:${toString cfg.passwordKeyLength}"
        fi

        # Generate registration
        if ! [ -f "${registrationFile}" ]; then
          ${bin} -c ${configFile} -f ${registrationFile} -r -u ${cfg.registrationUrl} -l ${cfg.localpart}
        fi

        # Allow synapse access to the registration
        if ${getBin pkgs.glibc}/bin/getent group matrix-synapse > /dev/null; then
          chgrp matrix-synapse ${registrationFile}
          chmod g+r ${registrationFile}
        fi
      '';

      serviceConfig = rec {
        Type = "simple";
        ExecStart = "${bin} -c ${configFile} -f ${registrationFile} -p ${toString cfg.port}";

        ProtectHome = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        StateDirectory = "matrix-appservice-irc";
        StateDirectoryMode = "755";

        User = "matrix-appservice-irc";
        Group = "matrix-appservice-irc";

        CapabilityBoundingSet = [ "CAP_CHOWN" ] ++ optional (cfg.needBindingCap) "CAP_NET_BIND_SERVICE";
        AmbientCapabilities = CapabilityBoundingSet;
        NoNewPrivileges = true;

        LockPersonality = true;
        RestrictRealtime = true;
        PrivateMounts = true;
        SystemCallFilter = "~@aio @clock @cpu-emulation @debug @keyring @memlock @module @mount @obsolete @raw-io @setuid @swap";
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = "AF_INET AF_INET6";
      };
    };

    users.groups.matrix-appservice-irc = {};
    users.users.matrix-appservice-irc = {
      description = "Service user for the Matrix-IRC bridge";
      group = "matrix-appservice-irc";
      isSystemUser = true;
    };
  };
}
