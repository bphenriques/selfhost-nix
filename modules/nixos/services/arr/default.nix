# The *arr apps: radarr and sonarr share the media-arr builder, prowlarr is wiring only. No acquisition config.
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
      unmonitorDeletedField = "autoUnmonitorPreviouslyDownloadedMovies";
      defaultExporterPort = 9710;
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
      unmonitorDeletedField = "autoUnmonitorPreviouslyDownloadedEpisodes";
      defaultExporterPort = 9709;
    })
    ./prowlarr.nix
  ];
}
