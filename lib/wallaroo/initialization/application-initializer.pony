use "collections"
use "net"
use "sendence/dag"
use "sendence/guid"
use "sendence/messages"
use "wallaroo"
use "wallaroo/messages"
use "wallaroo/metrics"
use "wallaroo/topology"
use "wallaroo/resilience"

actor ApplicationInitializer
  let _auth: AmbientAuth
  let _guid_gen: GuidGenerator = GuidGenerator
  let _local_topology_initializer: LocalTopologyInitializer
  let _input_addrs: Array[Array[String]] val
  let _output_addr: Array[String] val
  let _alfred: Alfred tag

  var _application: (Application val | None) = None

  new create(auth: AmbientAuth,
    local_topology_initializer: LocalTopologyInitializer,
    input_addrs: Array[Array[String]] val, 
    output_addr: Array[String] val, alfred: Alfred tag) 
  =>
    _auth = auth
    _local_topology_initializer = local_topology_initializer
    _input_addrs = input_addrs
    _output_addr = output_addr
    _alfred = alfred

  be update_application(app: Application val) =>
    _application = app

  be initialize(worker_initializer: WorkerInitializer, worker_count: USize,
    worker_names: Array[String] val)
  =>
    match _application
    | let a: Application val =>
      @printf[I32]("Initializing application\n".cstring())
      _automate_initialization(a, worker_initializer, worker_count, 
        worker_names, _alfred)
    else
      @printf[I32]("No application provided!\n".cstring())
    end

  be topology_ready() =>
    @printf[I32]("Application has successfully initialized.\n".cstring())

    match _application
    | let app: Application val =>
      for i in Range(0, _input_addrs.size()) do
        try
          let init_file = app.init_files(i)
          let file = InitFileReader(init_file, _auth)
          file.read_into(_input_addrs(i))
        end
      end
    end

  fun ref _automate_initialization(application: Application val,
    worker_initializer: WorkerInitializer, worker_count: USize,
    worker_names: Array[String] val, alfred: Alfred tag)
  =>
    @printf[I32]("---------------------------------------------------------\n".cstring())
    @printf[I32]("^^^^^^Initializing Topologies for Workers^^^^^^^\n\n".cstring())
    try
      // Keep track of shared state so that it's only created once
      let state_partition_map: Map[String, PartitionAddresses val] trn =
        recover Map[String, PartitionAddresses val] end

      var pipeline_id: USize = 0

      // Map from step_id to worker name
      let steps: Map[U128, String] = steps.create()

      // We use these graphs to build the local graphs for each worker
      let local_graphs: Map[String, Dag[StepInitializer val] trn] trn =  
        recover Map[String, Dag[StepInitializer val] trn] end

      // Initialize values for local graphs
      local_graphs("initializer") = Dag[StepInitializer val]
      for name in worker_names.values() do
        local_graphs(name) = Dag[StepInitializer val]
      end

      @printf[I32](("Found " + application.pipelines.size().string()  + " pipelines in application\n").cstring())

      // Break each pipeline into LocalPipelines to distribute to workers
      for pipeline in application.pipelines.values() do
        if not pipeline.is_coalesced() then
          @printf[I32](("Coalescing is off for " + pipeline.name() + " pipeline\n").cstring())
        end

        let source_addr_trn: Array[String] trn = recover Array[String] end
        try
          source_addr_trn.push(_input_addrs(pipeline_id)(0))
          source_addr_trn.push(_input_addrs(pipeline_id)(1))
        else
          @printf[I32]("No input address!\n".cstring())
          error
        end
        let source_addr: Array[String] val = consume source_addr_trn

        let sink_addr: Array[String] trn = recover Array[String] end
        try
          sink_addr.push(_output_addr(0))
          sink_addr.push(_output_addr(1))
        else
          @printf[I32]("No output address!\n".cstring())
          error
        end

        @printf[I32](("The " + pipeline.name() + " pipeline has " + pipeline.size().string() + " uncoalesced runner builders\n").cstring())


        //////////
        // Coalesce runner builders if we can
        var handled_source_runners = false
        var source_runner_builders: Array[RunnerBuilder val] trn =
          recover Array[RunnerBuilder val] end

        // We'll use this array when creating StepInitializers
        let runner_builders: Array[RunnerBuilder val] trn =
          recover Array[RunnerBuilder val] end

        var latest_runner_builders: Array[RunnerBuilder val] trn =
          recover Array[RunnerBuilder val] end

        for i in Range(0, pipeline.size()) do
          let r_builder = 
            try
              pipeline(i)
            else
              @printf[I32](" couldn't find pipeline for index\n".cstring())
              error
            end
          if r_builder.is_stateful() then
            if latest_runner_builders.size() > 0 then
              let seq_builder = RunnerSequenceBuilder(
                latest_runner_builders = recover Array[RunnerBuilder val] end
                )
              runner_builders.push(seq_builder)
            end
            runner_builders.push(r_builder)
            handled_source_runners = true
          elseif not pipeline.is_coalesced() then
            if handled_source_runners then
              runner_builders.push(r_builder)
            else
              source_runner_builders.push(r_builder)
              handled_source_runners = true
            end
          // If the developer specified an id, then this needs to be on
          // a separate step to be accessed by multiple pipelines
          elseif r_builder.id() != 0 then
            runner_builders.push(r_builder)
            handled_source_runners = true
          else
            if handled_source_runners then
              latest_runner_builders.push(r_builder)
            else
              source_runner_builders.push(r_builder)
            end
          end
        end

        if latest_runner_builders.size() > 0 then
          let seq_builder = RunnerSequenceBuilder(
            latest_runner_builders = recover Array[RunnerBuilder val] end)
          runner_builders.push(seq_builder)
        end

        // Create Source Initializer and add it to the graph for the
        // initializer worker.
        let source_node_id = _guid_gen.u128()
        let source_seq_builder = RunnerSequenceBuilder(
            source_runner_builders = recover Array[RunnerBuilder val] end) 
        let source_initializer = SourceData(source_node_id, 
          pipeline.source_builder(), source_seq_builder, source_addr)

        @printf[I32](("\nPreparing to spin up " + source_seq_builder.name() + " on source on initializer\n").cstring())

        try
          local_graphs("initializer").add_node(source_initializer, 
            source_node_id)
        else
          @printf[I32]("problem adding node to initializer graph\n".cstring())
          error
        end

        // The last (node_id, StepInitializer val) pair we created
        // Gets set to None when we cross to the next worker since it
        // doesn't need to know its immediate cross-worker predecessor.
        var last_initializer: ((U128, StepInitializer val) | None) = 
          (source_node_id, source_initializer)


        // Determine which steps go on which workers using boundary indices
        // Each worker gets a near-equal share of the total computations
        // in this naive algorithm
        let per_worker: USize =
          if runner_builders.size() <= worker_count then
            1
          else
            runner_builders.size() / worker_count
          end

        @printf[I32](("Each worker gets roughly " + per_worker.string() + " steps\n").cstring())

        let boundaries: Array[USize] = boundaries.create()
        // Since we put the source on the first worker, start at -1
        var count: ISize = -1
        for i in Range(0, worker_count) do
          count = count + per_worker.isize()

          // We don't want to cross a boundary to get to the worker
          // that is the "anchor" for the partition, so instead we
          // make sure it gets put on the same worker
          try
            match runner_builders((count + 1).usize()) 
            | let pb: PartitionBuilder val =>
              count = count + 1
            end
          end

          if (i == (worker_count - 1)) and
            (count < runner_builders.size().isize()) then
            // Make sure we cover all steps by forcing the rest on the
            // last worker if need be
            boundaries.push(runner_builders.size())
          else
            boundaries.push(count.usize())
          end
        end

        // Keep track of which runner_builder we're on in this pipeline
        var runner_builder_idx: USize = 0
        // Keep track of which worker's boundary we're using
        var boundaries_idx: USize = 0

        // For each worker, use its boundary value to determine which
        // runner_builders to use to create StepInitializers that will be
        // added to its LocalTopology
        while boundaries_idx < boundaries.size() do
          let boundary = 
            try
              boundaries(boundaries_idx)
            else
              @printf[I32](("No boundary found for boundaries_idx " + boundaries_idx.string() + "\n").cstring())
              error
            end

          let worker =
            if boundaries_idx == 0 then
              "initializer"
            else
              try
                worker_names(boundaries_idx - 1)
              else
                @printf[I32]("No worker found for idx!\n".cstring())
                error
              end
            end
          // Keep track of which worker follows this one in order
          let next_worker: (String | None) =
            try
              worker_names(boundaries_idx)
            else
              None
            end

          // Set up egress id for this worker for this pipeline
          let egress_id = _guid_gen.u128()

          // Make sure there are still runner_builders left in the pipeline.
          if runner_builder_idx < runner_builders.size() then
            var cur_step_id = _guid_gen.u128()

            // Until we hit the boundary for this worker, keep adding
            // stepinitializers from the pipeline
            while runner_builder_idx < boundary do
              var next_runner_builder: RunnerBuilder val =
                try
                  runner_builders(runner_builder_idx)
                else
                  @printf[I32](("No runner builder found for idx " + runner_builder_idx.string() + "\n").cstring())
                  error
                end

              // Stateful steps have to be handled differently since pre state
              // steps must be on the same workers as their corresponding
              // state steps
              if next_runner_builder.is_stateful() then
                // If this is partitioned state and we haven't handled this
                // shared state before, handle it.  Otherwise, just handle the
                // prestate.
                var state_name = ""
                match next_runner_builder
                | let pb: PartitionBuilder val =>
                  state_name = pb.state_name()
                  if not state_partition_map.contains(state_name) then
                    state_partition_map(state_name) = 
                      pb.partition_addresses(worker)
                  end
                end

                // Create the prestate initializer, and if this is not
                // partitioned state, then the state initializer as well.
                match next_runner_builder
                | let pb: PartitionBuilder val =>
                  @printf[I32](("Preparing to spin up partitioned state on " + worker + "\n").cstring())

                  // Determine whether the target step will be a step or a 
                  // sink/proxy
                  let pre_state_target_id =
                    try
                      runner_builders(runner_builder_idx + 1).id()
                    else
                      egress_id
                    end

                  let next_initializer = PartitionedPreStateStepBuilder(
                    pipeline.name(),
                    pb.pre_state_subpartition(worker), next_runner_builder,
                    state_name, pre_state_target_id)
                  let next_id = next_initializer.id()

                  try
                    local_graphs(worker).add_node(next_initializer, next_id)
                    match last_initializer
                    | (let last_id: U128, let step_init: StepInitializer val) 
                    =>
                      local_graphs(worker).add_edge(last_id, next_id)
                    end
                  else
                    @printf[I32](("Possibly no graph for worker " + worker + " when trying to spin up partitioned state\n").cstring())
                    error
                  end

                  last_initializer = (next_id, next_initializer) 
                  steps(next_id) = worker
                else
                  @printf[I32](("Preparing to spin up non-partitioned state computation for " + next_runner_builder.name() + " on " + worker + "\n").cstring())
                  let pre_state_id = next_runner_builder.id()

                  // Determine whether the target step will be a step or a 
                  // sink/proxy, hopping forward 2 because the next one
                  // should be our state step
                  let pre_state_target_id =
                    try
                      runner_builders(runner_builder_idx + 2).id()
                    else
                      egress_id
                    end

                  let pre_state_init = StepBuilder(pipeline.name(),
                    next_runner_builder, pre_state_id, 
                    next_runner_builder.is_stateful(), pre_state_target_id)

                  try
                    local_graphs(worker).add_node(pre_state_init, pre_state_id)
                    match last_initializer
                    | (let last_id: U128, let step_init: StepInitializer val) 
                    =>
                      local_graphs(worker).add_edge(last_id, pre_state_id)
                    end
                  else
                    @printf[I32](("No graph for worker " + worker + "\n").cstring())
                    error
                  end
                  
                  steps(next_runner_builder.id()) = worker

                  runner_builder_idx = runner_builder_idx + 1

                  next_runner_builder = 
                    try
                      runner_builders(runner_builder_idx)
                    else
                      @printf[I32](("No runner builder for idx " + runner_builder_idx.string() + "\n").cstring())
                      error
                    end

                  @printf[I32](("Preparing to spin up non-partitioned state for " + next_runner_builder.name() + " on " + worker + "\n").cstring())

                  let next_initializer = StepBuilder(pipeline.name(),
                    next_runner_builder, next_runner_builder.id(),
                    next_runner_builder.is_stateful())
                  let next_id = next_initializer.id()

                  try
                    local_graphs(worker).add_node(next_initializer, next_id)
                    local_graphs(worker).add_edge(pre_state_id, next_id)
                  else
                    @printf[I32](("No graph for worker " + worker + "\n").cstring())
                    error
                  end

                  last_initializer = None
                  steps(next_id) = worker
                end
              else
                @printf[I32](("Preparing to spin up " + next_runner_builder.name() + " on " + worker + "\n").cstring())
                let next_id = next_runner_builder.id()
                let next_initializer = StepBuilder(pipeline.name(),
                  next_runner_builder, next_id)

                try
                  local_graphs(worker).add_node(next_initializer, next_id)
                  match last_initializer
                  | (let last_id: U128, let step_init: StepInitializer val) =>
                    local_graphs(worker).add_edge(last_id, next_id)
                  end
                  
                  last_initializer = (next_id, next_initializer) 
                else
                  @printf[I32](("No graph for worker " + worker + "\n").cstring())
                  error
                end

                steps(next_id) = worker
              end

              runner_builder_idx = runner_builder_idx + 1
            end
          end

          // Create the EgressBuilder for this worker and add to its graph.
          // First, check if there is going to be a step across the boundary
          if runner_builder_idx < runner_builders.size() then
            ///////
            // We need a Proxy
            match next_worker
            | let w: String =>
              let proxy_address = 
                try
                  ProxyAddress(w, runner_builders(runner_builder_idx).id())
                else
                  @printf[I32](("No runner builder found for idx " + runner_builder_idx.string() + "\n").cstring())
                  error
                end
              let egress_builder = EgressBuilder(pipeline.name(),
                egress_id, proxy_address)

              try
                local_graphs(worker).add_node(egress_builder, egress_id)
                match last_initializer
                | (let last_id: U128, let step_init: StepInitializer val) =>
                  local_graphs(worker).add_edge(last_id, egress_id)
                end
              else
                @printf[I32](("No graph for worker " + worker + "\n").cstring())
                error
              end
            else
              // Something went wrong, since if there are more runner builders
              // there should be more workers
              @printf[I32]("Not all runner builders were assigned to a worker\n".cstring())
              error
            end
          else
            ///////
            // We need a Sink
            let egress_builder = EgressBuilder(pipeline.name(), 
              egress_id, _output_addr, pipeline.sink_builder())

            try
              local_graphs(worker).add_node(egress_builder, egress_id)
              match last_initializer
              | (let last_id: U128, let step_init: StepInitializer val) =>
                local_graphs(worker).add_edge(last_id, egress_id)
              end
            else
              @printf[I32](("No graph for worker " + worker + "\n").cstring())
              error
            end
          end

          // Reset the last initializer since we're moving to the next worker
          last_initializer = None
          // Move to next worker's boundary value
          boundaries_idx = boundaries_idx + 1
        end

        // Prepare to initialize the next pipeline
        pipeline_id = pipeline_id + 1
      end

      // Keep track of LocalTopologies that we need to send to other
      // (non-initializer) workers
      let other_local_topologies: Array[LocalTopology val] trn =
        recover Array[LocalTopology val] end

      // For each worker, generate a LocalTopology
      // from all of its LocalGraphs
      for (w, g) in local_graphs.pairs() do
        let local_topology = 
          try
            LocalTopology(application.name(), g.clone(),
              application.state_builders())
          else
            @printf[I32]("Problem cloning graph\n".cstring())
            error
          end

        // If this is the initializer's (i.e. our) turn, then
        // immediately (asynchronously) begin initializing it. If not, add it
        // to the list we'll use to distribute to the other workers
        if w == "initializer" then
          _local_topology_initializer.update_topology(local_topology)
          _local_topology_initializer.initialize(worker_initializer) 
        else
          other_local_topologies.push(local_topology)
        end
      end

      // Distribute the LocalTopologies to the other (non-initializer) workers
      match worker_initializer
      | let wi: WorkerInitializer =>
        wi.distribute_local_topologies(consume other_local_topologies)
      else
        @printf[I32]("Error distributing local topologies!\n".cstring())
      end

      @printf[I32]("\n^^^^^^Finished Initializing Topologies for Workers^^^^^^^\n".cstring())
      @printf[I32]("---------------------------------------------------------\n".cstring())
    else
      @printf[I32]("Error initializating application!\n".cstring())
    end