require 'concurrent/atomic/atomic_boolean'

class ManageIQ::Providers::Kubevirt::InfraManager::RefreshWorker::Runner < ManageIQ::Providers::BaseManager::RefreshWorker::Runner
  def do_before_work_loop
    # Always run full_refresh when worker is starting to make sure we use the latest versions
    full_refresh

    # We will put in this queue the notices received from the watchers:
    @queue = Queue.new

    # Create the thread that processes the notices from the queue and persists the results. It will
    # exit when it detects a `nil` in the queue.
    @processor = Thread.new do
      loop do
        # We want to process noticies in blocks, which will be stored in this array:
        notices = []

        # Wait till there is at least one notice in the queue:
        notice = @queue.pop
        notices.push(notice)

        # Fetch as many notices as are already available in the queue:
        until @queue.empty?
          notice = @queue.pop
          notices.push(notice)
        end

        # Check if the last notice in the block is `nil`, as that is the signal to stop:
        stop = notices.last.nil?

        # Remove the last `nil` notice, and process the rest of the block:
        notices.delete_at(notices.length - 1) if stop
        partial_refresh(notices)

        # Stop if signaled to do so:
        break if stop
      end
    end

    # start watches
    start_watches
  end

  def before_exit(_message, _exit_code)
    # Ask the watch threads to finish, and wait for them:
    stop_watches
    @watchers&.each(&:join)

    # Ask the processor thread to finish, and wait for it:
    @queue&.push(nil)
    @processor&.join
  end

  private

  def provider_class
    ManageIQ::Providers::Kubevirt
  end

  def manager_class
    provider_class::InfraManager
  end

  def collector_class
    provider_class::Inventory::Collector
  end

  def partial_refresh_parser_class
    provider_class::Inventory::Parser::PartialRefresh
  end

  def persister_class
    provider_class::Inventory::Persister
  end

  #
  # Returns the reference to the manager.
  #
  # @return [ManageIQ::Providers::Kubevirt::InfraManager] The manager.
  #
  def manager
    @manager ||= manager_class.find(@cfg[:ems_id])
  end

  #
  # Returns the refresh memory.
  #
  # @return [ManageIQ::Providers::Kubevirt::RefreshMemory] The refresh memory.
  #
  def memory
    @memory ||= manager_class::RefreshMemory.new
  end

  #
  # Performs a full refresh.
  #
  def full_refresh
    # Create and populate the collector, persister and parser
    # and parse inventories
    inventory = provider_class::Inventory.build(manager, nil)
    collector = inventory.collector
    persister = inventory.parse

    # execute persist:
    persister&.persist!

    # Update the memory:
    memory.add_list_version(:nodes, collector.nodes.resourceVersion)
    memory.add_list_version(:vms, collector.vms.resourceVersion)
    memory.add_list_version(:vm_instances, collector.vm_instances.resourceVersion)
    memory.add_list_version(:templates, collector.templates.resourceVersion)
    memory.add_list_version(:instance_types, collector.instance_types.resourceVersion)

    manager.update(:last_refresh_error => nil, :last_refresh_date => Time.now.utc)
  rescue StandardError => error
    _log.error('Full refresh failed.')
    _log.log_backtrace(error)
    manager.update(:last_refresh_error => error.to_s, :last_refresh_date => Time.now.utc)
  end

  #
  # Performs a partial refresh.
  #
  # @param notices [Array] The set of notices to process.
  #
  def partial_refresh(notices)
    # check whether we get error about stale resource version
    if notices.any? { |notice| notice.object&.kind == "Status" && notice.object&.code == 410 }
      # base on the structure we do not know which watch uses stale version so we stop all
      # we can't join with all the threads since we are in one
      stop_watches

      # clear queue
      @queue.clear

      # get the latest state and resource versions
      full_refresh

      # restart watches
      start_watches
      return
    end

    # Filter out the notices that have already been processed:
    notices.reject! do |notice|
      if memory.contains_notice?(notice)
        _log.info(
          "Notice of kind '#{notice.object.kind}, id '#{notice.object.metadata.uid}', type '#{notice.type}' and version '#{notice.resource_version}' " \
          "has already been processed, will ignore it."
        )
        true
      else
        false
      end
    end

    # The notices returned by the Kubernetes API contain always the complete representation of the object, so it isn't
    # necessary to process all of them, only the last one for each object.
    relevant = notices.reverse!
    relevant.uniq!(&:uid)
    relevant.reverse!

    # Create and populate the collector:
    collector = collector_class.new(manager, nil)
    collector.nodes = notices_of_kind(relevant, 'Node')
    collector.vms = notices_of_kind(relevant, 'VirtualMachine')
    collector.vm_instances = notices_of_kind(relevant, 'VirtualMachineInstance')
    collector.templates = notices_of_kind(relevant, 'VirtualMachineTemplate')
    collector.instance_types = notices_of_kind(relevant, 'VirtualMachineClusterInstanceType')

    # Create the parser and persister, wire them, and execute the persist:
    persister = persister_class.new(manager, nil)
    parser = partial_refresh_parser_class.new
    parser.collector = collector
    parser.persister = persister
    parser.parse
    persister.persist!

    # Update the memory:
    notices.each do |notice|
      memory.add_notice(notice)
    end

    manager.update(:last_refresh_error => nil, :last_refresh_date => Time.now.utc)
  rescue StandardError => error
    _log.error('Partial refresh failed.')
    _log.log_backtrace(error)
    manager.update(:last_refresh_error => error.to_s, :last_refresh_date => Time.now.utc)
  end

  #
  # Returns the notices that contain objects of the given kind.
  #
  # @param notices [Array] An array of notices.
  # @param kind [String] The kind of object, for example `Node`.
  # @return [Array] An array containing the notices that have the given kind.
  #
  def notices_of_kind(notices, kind)
    notices.select { |notice| notice.object.kind == kind }
  end

  #
  # Start watches
  #
  def start_watches
    # This flag will be used to tell the threads to get out of their loops:
    @finish = Concurrent::AtomicBoolean.new(false)

    # Create the watches:
    @watches = []
    @watches << @manager.kubeclient.watch_nodes(:resource_version => memory.get_list_version(:nodes))
    @watches << @manager.kubeclient("kubevirt.io/v1").watch_virtual_machines(:resource_version => memory.get_list_version(:vms))
    @watches << @manager.kubeclient("kubevirt.io/v1").watch_virtual_machine_instances(:resource_version => memory.get_list_version(:vm_instances))
    @watches << @manager.kubeclient("template.openshift.io/v1").watch_templates(:resource_version => memory.get_list_version(:templates))
    @watches << @manager.kubeclient("instancetype.kubevirt.io/v1beta1").watch_virtual_machine_cluster_instancetypes(:resource_version => memory.get_list_version(:instance_types))

    # Create the threads that run the watches and put the notices in the queue:
    @watchers = []
    @watches.each do |watch|
      thread = Thread.new do
        until @finish.value
          watch.each do |notice|
            @queue.push(notice)
          end
        end
      end
      @watchers << thread
    end
  end

  #
  # Stop all the watches
  #
  def stop_watches
    @finish&.value = true
    @watches&.each(&:finish)
  end
end
