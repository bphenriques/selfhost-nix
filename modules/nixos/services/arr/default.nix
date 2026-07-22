# First-party *arr apps (selfhost.apps.{radarr,sonarr,prowlarr}). radarr/sonarr share the media-arr builder;
# prowlarr is wiring-only. The framework wires plumbing (ingress, auth, secrets, notify, backup, root
# folders, download clients) and ships zero acquisition config — indexers and quality profiles are the
# consumer's, kept in their own/private config.
{
  imports = [
    (import ./media-arr.nix {
      name = "radarr";
      displayName = "Radarr";
      description = "Movie Library";
      homepage = "https://radarr.video";
      defaultPort = 7878;
      icon = "radarr.svg";
      notifyTags = "movie_camera";
      backupResource = {
        path = "movie";
        file = "movies.json";
      };
    })
    (import ./media-arr.nix {
      name = "sonarr";
      displayName = "Sonarr";
      description = "TV Library";
      homepage = "https://sonarr.tv";
      defaultPort = 8989;
      icon = "sonarr.svg";
      notifyTags = "tv";
      backupResource = {
        path = "series";
        file = "series.json";
      };
    })
    ./prowlarr.nix
  ];
}
