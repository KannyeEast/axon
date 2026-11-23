{
  axon.features.metrics = {
    description = "Exporters for the system, its disks and databases, scraped by the host running monitoring, and the journal, shipped to it";
    classes = [
      "desktop"
      "server"
    ];
    metrics = {
      node.port = 9100;
      smartctl.port = 9633;
    };
  };
}
