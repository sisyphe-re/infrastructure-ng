{ django-toolbox }: { lib, pkgs, config, ... }:
with lib;
let
  cfg = config.services.sisyphe;
  pythonWithDjango = pkgs.python3.withPackages (p: [
    p.django_3
    p.psycopg2
    p.daphne
    p.celery
    p.cryptography
    p.python-crontab
    (pkgs.python3Packages.toPythonModule django-toolbox.packages.x86_64-linux.django-celery-beat)
    (pkgs.python3Packages.toPythonModule django-toolbox.packages.x86_64-linux.django-timezone-field)
  ]);
in
{
  imports = [
  ];

  options = {
    services.sisyphe = {
      enable = mkEnableOption "sisyphe service";
      host = mkOption {
        type = types.str;
        default = "sisyphe2.grunblatt.org";
      };
      rabbitmqPort = mkOption {
        type = types.int;
        default = 5672;
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
    };
  };

  config = mkIf cfg.enable {

    services.rabbitmq = {
      enable = true;
      listenAddress = "0.0.0.0";
      configItems = {
        "default_user" = "${cfg.rabbitmqUsername}";
        "default_pass" = "${cfg.rabbitmqPassword}";
        "default_vhost" = "${cfg.rabbitmqVhost}";
      };
    };

    networking.firewall = {
      allowedTCPPorts = [ cfg.rabbitmqPort ];
    };

    systemd.services.celery = {
      enable = true;
      description = "The sisyphe celery server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "rabbitmq.service" ];
      environment = {
        DEBUG = "${cfg.djangoDebug}";
        SHELL = "bash";
        DB_NAME = "${cfg.djangoDbPath}";
        DJANGO_HOST = "${cfg.host}";
        DJANGO_SECRET_KEY = "${cfg.djangoSecretKey}";
        AMQP_PASSWORD = "${cfg.rabbitmqPassword}";
        AMQP_USER = "${cfg.rabbitmqUsername}";
        AMQP_HOST = "${cfg.rabbitmqVhost}";
        AMQP_AUTHORITY = "${cfg.host}";
        AMQP_PORT = "${builtins.toString cfg.rabbitmqPort}";
      };
      serviceConfig = {
        ExecStart = pkgs.writeScript "celery" ''#!${pkgs.runtimeShell} -l
        export PATH=''${PATH}:${pkgs.nix}/bin:${pkgs.git}/bin:${pkgs.gnutar}/bin:${pkgs.gzip}/bin:${pkgs.nix}/bin:${pkgs.nix}/bin
        cd /var/lib/sisyphe;
        env;
        whoami;
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
      BindReadOnlyPaths = [
        "/tmp/daphne.sock"
      ];
    };

    services.nginx = {
      additionalModules = [ pkgs.nginxModules.fancyindex ];
      enable = true;
      preStart = "mkdir -p /data/nginx/cache";
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      appendHttpConfig = ''
        proxy_cache_path /data/nginx/cache levels=1:2 keys_zone=sisyphe:720m inactive=24h max_size=1g;
      '';
      virtualHosts."${cfg.host}" = {
        enableACME = true;
        forceSSL = true;
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
    };
    networking.nat.enable = true;
    networking.nat.internalInterfaces = [ "ve-+" ];
    networking.nat.externalInterface = "enp1s0";

    networking.firewall.allowedTCPPortRanges = [
      { from = 10000; to = 65535; }
    ];

    environment.systemPackages = [
      pkgs.qemu_full
      pkgs.samba4Full
      pkgs.libguestfs-with-appliance
    ];

    users.users.sisyphe = {
      uid = 1337;
      isSystemUser = true;
      createHome = true;
      home = "/home/sisyphe/";
      extraGroups = [ "wheel" ];
    };

    systemd.tmpfiles.rules = [
      "d /home/sisyphe 0755 sisyphe sisyphe"
    ];

    security.sudo.extraRules = [
      {
        users = [ "sisyphe" ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ]; # "SETENV" # Adding the following could be a good idea
          }
        ];
      }
    ];

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
        AMQP_AUTHORITY = "${cfg.host}";
        AMQP_PORT = "${builtins.toString cfg.rabbitmqPort}";
      };
      script = ''
        cd /var/lib/sisyphe &&
        ${pythonWithDjango}/bin/python manage.py makemigrations &&
        ${pythonWithDjango}/bin/python manage.py migrate &&
        ${pythonWithDjango}/bin/python manage.py collectstatic --noinput &&
        echo "from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.filter(username='${cfg.djangoUsername}').exists() or User.objects.create_superuser('${cfg.djangoUsername}', '${cfg.djangoEmail}', '${cfg.djangoPassword}')" | ${pythonWithDjango}/bin/python manage.py shell &&
        ${pythonWithDjango}/bin/daphne -u /tmp/daphne.sock sisyphe.asgi:application
      '';
      serviceConfig = {
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/rm -rf /var/lib/sisyphe"
          "+${pkgs.coreutils}/bin/cp -r ${../../sisyphe}/. /var/lib/sisyphe"
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
