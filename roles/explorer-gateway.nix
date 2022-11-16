pkgs: { config, nodes, ... }:
with pkgs;
let backendAddr = let
  suffix = {
    ec2 = "-ip";
    libvirtd = "";
    packet = "";
  }.${config.deployment.targetEnv};
  in name: if (globals.explorerBackendsInContainers)
    then "${name}.containers"
    else "explorer-${name}${suffix}";
in {

  imports = [
    cardano-ops.modules.common
  ];

  environment.systemPackages = with pkgs; [
    bat fd lsof netcat ncdu ripgrep tree vim dnsutils
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 8080 ];

  services.traefik = {
    enable = true;

    staticConfigOptions = {
      api.dashboard = false;
      metrics.prometheus = {
        entryPoint = "metrics";
      };
      entryPoints = {
        web = {
          address = ":80";
          http = {
            redirections = {
              entryPoint = {
                to = "websecure";
                scheme = "https";
              };
            };
          };
        };
        websecure = {
          address = ":443";
        };
        metrics = {
          address = ":${toString globals.cardanoExplorerGwPrometheusExporterPort}";
        };
      };
      certificatesResolvers.default.acme = {
        email = "devops@iohk.io";
        storage = "/var/lib/traefik/acme.json";
        httpChallenge = {
          entryPoint = "web";
        };
      };
    };
    dynamicConfigOptions = {
      http = {
        routers = {
          #traefik = {
          #  rule = (lib.concatStringsSep " || "
          #    (map (a: "Host(`${a}`)") ([globals.explorerHostName] ++ globals.explorerAliases))) + " && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))";
          #  service = "api@internal";
          #  tls.certResolver = "default";
          #};
          rosetta = {
            rule = (lib.concatStringsSep " || "
              (map (a: "Host(`${a}`)") ([globals.explorerHostName] ++ globals.explorerAliases))) + " && PathPrefix(`/rosetta`)";
            service = "rosetta";
            tls.certResolver = "default";
          };
          explorer = {
            rule = lib.concatStringsSep " || "
              (map (a: "Host(`${a}`)") ([globals.explorerHostName] ++ globals.explorerAliases));
            service = "explorer";
            tls.certResolver = "default";
          };
          smash = {
            rule = "Host(`smash.${globals.domain}`)";
            service = "smash";
            tls.certResolver = "default";
          };
        };
        services = {
          rosetta = {
            loadBalancer = {
              servers = map (b: {
                url = "http://${backendAddr b}";
              }) globals.explorerRosettaActiveBackends;
            };
          };
          explorer = {
            loadBalancer = {
              servers = map (b: {
                url = "http://${backendAddr b}";
              }) globals.explorerActiveBackends;
            };
          };
          smash = {
            loadBalancer = {
              servers = map (b: {
                url = "http://${backendAddr b}:81";
              }) globals.explorerActiveBackends;
            };
          };
        };
      };
    };
  };

  # Reduce default interval to allow for more restarts (5 in 1 min) before it fails
  systemd.services.traefik.startLimitIntervalSec = lib.mkForce 60;

  services.monitoring-exporters.extraPrometheusExporters = [
    {
      job_name = "explorer-gateway-exporter";
      scrape_interval = "10s";
      metrics_path = "/metrics";
      port = globals.cardanoExplorerGwPrometheusExporterPort;
    }
  ];

  services.dnsmasq.enable = true;

  networking.nat = {
    enable = globals.explorerBackendsInContainers;
    internalInterfaces = [ "ve-+" ];
    externalInterface = "ens5";
  };
  networking.firewall.trustedInterfaces = config.networking.nat.internalInterfaces;

  containers = lib.optionalAttrs globals.explorerBackendsInContainers (let
    indexes = lib.listToAttrs (lib.imap1 (lib.flip lib.nameValuePair) (lib.attrNames globals.explorerBackends));
  in
    lib.mapAttrs (z: variant: let
      hostAddress = "192.168.100.${toString indexes.${z}}0";
      localAddress = "192.168.100.${toString indexes.${z}}1";
    in {
      privateNetwork = true;
      autoStart = true;
      inherit hostAddress localAddress;
      config = {
        _module.args = {
          name = "explorer-${z}";
          nodes = nodes // {
            "explorer-${z}" = {
              config.networking.privateIPv4 = localAddress;
              options.networking.privateIPv4.isDefined = true;
              options.networking.publicIPv4.isDefined = false;
            };
          };
          resources = {};
        };
        nixpkgs.pkgs = pkgs;
        imports = [(cardano-ops.roles.explorer variant)];
        networking.nameservers = [ hostAddress ];
        node = {
          nodeId = config.node.nodeId + 1;
          memory = config.node.memory / (lib.length (lib.attrNames globals.explorerBackends));
        };
      };
    }) globals.explorerBackends
  );
}
