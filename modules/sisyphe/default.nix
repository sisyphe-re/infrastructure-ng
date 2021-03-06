{ lib, pkgs, config, rgrunbla-pkgs, vm, ... }:
with lib;
let
  cfg = config.services.sisyphe;
  my_python = pkgs.python3.override {
    packageOverrides = self: super: {
      django = super.django_3;
    };
  };
  django-celery-beat = (my_python.pkgs.toPythonModule
    rgrunbla-pkgs.packages.x86_64-linux.django-celery-beat);
  pythonWithDjango = my_python.withPackages (p: [
    p.libvirt
    p.psycopg2
    p.daphne
    p.celery
    p.cryptography
    p.python-crontab
    p.djangorestframework
    p.markdown
    p.django-filter
    p.django-timezone-field
    django-celery-beat
  ]);
in
{
  options = {
    services.sisyphe = {
      enable = mkEnableOption "sisyphe service";
      host = mkOption {
        type = types.str;
        default = "sisyphe-api.grunblatt.org";
      };
      cacheHost = mkOption {
        type = types.str;
        default = "cache.grunblatt.org";
      };
      dataDir = mkOption {
        type = types.str;
        default = "/var/lib/sisyphe";
        description = "Directory to store the sisyphe server data.";
      };
      rabbitmqPort = mkOption {
        type = types.int;
        default = 5672;
      };
      rabbitmqHost = mkOption {
        type = types.str;
        default = "localhost";
      };
      rabbitmqVhost = mkOption {
        type = types.str;
        default = "testvhost";
      };
      rabbitmqUsername = mkOption {
        type = types.str;
        default = "testuser";
      };
      rabbitmqPassword = mkOption {
        type = types.str;
        default = "testpassword";
      };
      djangoUsername = mkOption {
        type = types.str;
        default = "testuser";
      };
      djangoPassword = mkOption {
        type = types.str;
        default = "testpassword";
      };
      djangoEmail = mkOption {
        type = types.str;
        default = "test@example.com";
      };
      djangoSecretKey = mkOption {
        type = types.str;
        default = "averylongstringwhichisrandom";
      };
      djangoDbPath = mkOption {
        type = types.str;
        default = "/data/sisyphe.db3";
      };
      djangoDebug = mkOption {
        type = types.str;
        default = "False";
      };
      enableTls = mkOption {
        type = types.bool;
        default = false;
      };
    };
  };

  config = mkIf cfg.enable {

    services.rabbitmq = {
      enable = true;
      listenAddress = "0.0.0.0";
      configItems = {
        "consumer_timeout" = "86400000";
        "default_user" = "${cfg.rabbitmqUsername}";
        "default_pass" = "${cfg.rabbitmqPassword}";
        "default_vhost" = "${cfg.rabbitmqVhost}";
      };
    };

    virtualisation.libvirtd = {
      enable = true;
      qemu.package = pkgs.qemu_full;
    };

    networking.firewall = { allowedTCPPorts = [ cfg.rabbitmqPort ]; };

    systemd.services.celery = {
      enable = true;
      description = "The sisyphe celery server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "rabbitmq.service" "sisyphe.service" ];
      environment = {
        DEBUG = "${cfg.djangoDebug}";
        SHELL = "bash";
        DB_NAME = "${cfg.djangoDbPath}";
        DJANGO_HOST = "${cfg.host}";
        DJANGO_SECRET_KEY = "${cfg.djangoSecretKey}";
        AMQP_PASSWORD = "${cfg.rabbitmqPassword}";
        AMQP_USER = "${cfg.rabbitmqUsername}";
        AMQP_HOST = "${cfg.rabbitmqVhost}";
        AMQP_AUTHORITY = "${cfg.rabbitmqHost}";
        AMQP_PORT = "${builtins.toString cfg.rabbitmqPort}";
        SISYPHE_ISO_PATH = "${vm.packages.x86_64-linux.iso.out}";
      };
      serviceConfig = {
        ExecStart = pkgs.writeScript "celery" ''
          #!${pkgs.runtimeShell} -l
                    export PATH=''${PATH}:${pkgs.nix}/bin:${pkgs.git}/bin:${pkgs.gnutar}/bin:${pkgs.gzip}/bin:${pkgs.nix}/bin:${pkgs.nix}/bin
                    cd ${cfg.dataDir}/src
                    ${pythonWithDjango}/bin/celery -A sisyphe worker -B
        '';
        User = "sisyphe";
        Group = "sisyphe";
      };
    };

    security.acme.email = "remy@grunblatt.org";
    security.acme.acceptTerms = true;

    users.users.nginx.extraGroups = [ "sisyphe" ];
    systemd.services.nginx.serviceConfig = {
      ProtectHome = "read-only";
      BindReadOnlyPaths = [ "/tmp/daphne.sock" ];
    };

    services.nginx = {
      additionalModules = [ pkgs.nginxModules.fancyindex ];
      enable = true;
      preStart = "mkdir -p /data/nginx/cache";
      recommendedProxySettings = true;
      recommendedTlsSettings = cfg.enableTls;
      appendHttpConfig = ''
        proxy_cache_path /data/nginx/cache levels=1:2 keys_zone=sisyphe:720m inactive=24h max_size=1g;
      '';
      virtualHosts = {
        "${cfg.host}" = {
          enableACME = cfg.enableTls;
          forceSSL = cfg.enableTls;
          locations."@sisyphe_cache" = {
            proxyPass = "http://unix:/tmp/daphne.sock";
            extraConfig = ''
              add_header X-Cache $upstream_cache_status;
              proxy_cache sisyphe;
              proxy_cache_valid 24h;
              proxy_cache_use_stale updating error timeout http_500 http_502 http_503 http_504;
              proxy_cache_background_update on;
              proxy_cache_key "$scheme://$host$request_method$request_uri";
              proxy_connect_timeout       300;
              proxy_send_timeout          300;
              proxy_read_timeout          300;
              send_timeout                300;
            '';
          };
          locations."/" = { proxyPass = "http://unix:/tmp/daphne.sock"; };
          locations."/static/" = { alias = "/var/www/static/"; };
          locations."/artifacts/" = {
            alias = "/home/sisyphe/";
            extraConfig = ''
              autoindex on;
              fancyindex on;
              fancyindex_localtime on;
              fancyindex_exact_size off;
              fancyindex_name_length 255;
              fancyindex_ignore "store";
            '';
          };
        };

        "~^(?<subdomain>.+)\.${cfg.cacheHost}$" = {
          forceSSL = cfg.enableTls;
          locations."/" = {
            root = "/home/sisyphe/$subdomain/store";
          };
          extraConfig = ''
            autoindex on;
          '';
        };
      };
    };

    networking.nat.enable = true;
    networking.nat.internalInterfaces = [ "ve-+" ];
    networking.nat.externalInterface = "enp1s0";

    networking.firewall.allowedTCPPortRanges = [{
      from = 10000;
      to = 65535;
    }];

    environment.systemPackages = [
      pkgs.qemu_full
      pkgs.libvirt
      pkgs.samba4Full
      pkgs.libguestfs-with-appliance
    ];

    users.groups.sisyphe = { };

    users.users.sisyphe = {
      group = "sisyphe";
      uid = 1337;
      isSystemUser = true;
      createHome = true;
      home = "/home/sisyphe/";
      extraGroups = [ "wheel" ];
    };

    systemd.tmpfiles.rules = [ "d /home/sisyphe 0755 sisyphe sisyphe" ];

    security.sudo.extraRules = [{
      users = [ "sisyphe" ];
      commands = [{
        command = "ALL";
        options =
          [ "NOPASSWD" ]; # "SETENV" # Adding the following could be a good idea
      }];
    }];

    users.groups.sisyphe = {
      gid = 1337;
      members = [ "sisyphe" ];
    };

    systemd.services.sisyphe = {
      description = "The sisyphe django server";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      after = [ "network.target" ];
      environment = {
        DEBUG = "${cfg.djangoDebug}";
        DB_NAME = "${cfg.djangoDbPath}";
        DJANGO_HOST = "${cfg.host}";
        DJANGO_SECRET_KEY = "${cfg.djangoSecretKey}";
        AMQP_PASSWORD = "${cfg.rabbitmqPassword}";
        AMQP_USER = "${cfg.rabbitmqUsername}";
        AMQP_HOST = "${cfg.rabbitmqVhost}";
        AMQP_AUTHORITY = "${cfg.rabbitmqHost}";
        AMQP_PORT = "${builtins.toString cfg.rabbitmqPort}";
        SISYPHE_ISO_PATH = "${vm.packages.x86_64-linux.iso.out}";
      };
      script = ''
        cd ${cfg.dataDir}/src &&
        ${pythonWithDjango}/bin/python manage.py migrate --noinput &&
        ${pythonWithDjango}/bin/python manage.py collectstatic --noinput &&
        ${pythonWithDjango}/bin/daphne -u /tmp/daphne.sock sisyphe.asgi:application
      '';
      serviceConfig = {
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/rm -rf ${cfg.dataDir}/src"
          "+${pkgs.coreutils}/bin/cp -r ${../../sisyphe}/. ${cfg.dataDir}/src"
          "+${pkgs.coreutils}/bin/chown -R sisyphe:sisyphe /var/lib/sisyphe"
          "+${pkgs.coreutils}/bin/chmod ug+w -R /var/lib/sisyphe"
        ];
        WorkingDirectory = "/var/lib/sisyphe";
        StateDirectory = "sisyphe";
        RestartSec = 5;
        User = "sisyphe";
        Group = "sisyphe";
      };
    };
  };
}
