export const repository = "https://github.com/edjubert/review.nvim";

export function metadata(manifest, web, binaries) {
  return {
    kind: "tab",
    package: {
      tab: {
        id: manifest.id,
        name: manifest.name,
        description: manifest.description,
        version: manifest.version,
        repository,
        license: "MIT",
        api_version: manifest.api_version,
        backend: {
          protocol: manifest.backend.protocol,
          reasoning: manifest.backend.reasoning,
        },
        distribution: { archive: web.archive, sha256: web.sha256, binary: binaries },
      },
      host: {
        publisher: "edjubert",
        compatibility: { min_app_version: "0.16.0" },
      },
    },
  };
}
