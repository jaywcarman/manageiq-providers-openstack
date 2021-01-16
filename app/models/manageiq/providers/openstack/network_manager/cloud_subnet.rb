class ManageIQ::Providers::Openstack::NetworkManager::CloudSubnet < ::CloudSubnet
  include ManageIQ::Providers::Openstack::HelperMethods
  include ProviderObjectMixin
  include SupportsFeatureMixin

  supports :create
  supports :delete do
    if ext_management_system.nil?
      unsupported_reason_add(:delete, _("The subnet is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
    if number_of(:vms) > 0
      unsupported_reason_add(:delete, _("The subnet has an active %{table}") % {
        :table => ui_lookup(:table => "vm_cloud")
      })
    end
  end
  supports :update do
    if ext_management_system.nil?
      unsupported_reason_add(:update, _("The subnet is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  def self.params_for_create(ems)
    {
      :fields => [
        # TODO: Sub-forms for 1) "Network Management Provider" and 2) "Cloud Subnet details" sections?
        # Network Management Provider
        {
          :component => 'select',
          :name      => 'cloud_tenant_placement',
          :id        => 'cloud_tenant_placement',
          :label     => _('Cloud Tenant Placement'),
          # TODO: Get list of tenents for selected network manager
          :options   => ems.cloud_volume_types.map do |cvt|
            {
              :label => cvt.description,
              :value => cvt.name,
            }
          end,
        },
        # Cloud Subnet details
        {
          :component => 'select',
          :name      => 'network',
          :id        => 'network',
          :label     => _('Network'),
          # TODO: Get list of networks in selected network manager
          :options   => ems.cloud_volume_types.map do |cvt|
            {
              :label => cvt.description,
              :value => cvt.name,
            }
          end,
          :isRequired => true,
          :validate   => [{:type => 'required'}]
        },
        {
          :component => 'text-field',
          :id        => 'subnet_name',
          :name      => 'subnet_name',
          :label     => _('Subnet Name'),
        },
        {
          :component => 'text-field',
          :id        => 'gateway',
          :name      => 'gateway',
          :label     => _('Gateway'),
        },
        {
          :component => 'switch',
          :id        => 'dhcp',
          :name      => 'dhcp',
          :label     => _('DHCP'),
          :onText    => 'Enabled',
          :offText   => 'Disabled',
        },
        {
          :component => 'select',
          :name      => 'ip_version',
          :id        => 'ip_version',
          :label     => _('IP Version'),
          :options   => [
            {
              :label => 'ipv4',
              :value => 'ipv4',
            },
            {
              :label => 'ipv6',
              :value => 'ipv6',
            }
          ]
        },
        {
          :component => 'text-field',
          :id        => 'subnet_cidr',
          :name      => 'subnet_cidr',
          :label     => _('Subnet CIDR'),
          :isRequired => true,
          :validate   => [{:type => 'required'}]
        },
        {
          :component => 'text-area',
          :id        => 'allocation_pools',
          :name      => 'allocation_pools',
          :label     => _('Allocation Pools'),
        },
        {
          :component => 'text-area',
          :id        => 'dns_servers',
          :name      => 'dns_servers',
          :label     => _('DNS Servers'),
        },
        {
          :component => 'text-area',
          :id        => 'host_routes',
          :name      => 'host_routes',
          :label     => _('Host Routes'),
        },
      ],
    }
  end
  def self.raw_create_cloud_subnet(ext_management_system, options)
    cloud_tenant = options.delete(:cloud_tenant)
    subnet = nil

    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      subnet = service.subnets.new(options)
      subnet.save
    end
    {:ems_ref => subnet.id, :name => options[:name]}
  rescue => e
    _log.error "subnet=[#{options[:name]}], error: #{e}"
    raise MiqException::MiqCloudSubnetCreateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_cloud_subnet
    with_notification(:cloud_subnet_delete,
                      :options => {
                        :subject => self,
                      }) do
      ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
        service.delete_subnet(ems_ref)
      end
    end
  rescue => e
    _log.error "subnet=[#{name}], error: #{e}"
    raise MiqException::MiqCloudSubnetDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def delete_cloud_subnet_queue(userid)
    task_opts = {
      :action => "deleting Cloud Subnet for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_delete_cloud_subnet',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_update_cloud_subnet(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_subnet(ems_ref, options)
    end
  rescue => e
    _log.error "subnet=[#{name}], error: #{e}"
    raise MiqException::MiqCloudSubnetUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_cloud_subnet_queue(userid, options = {})
    task_opts = {
      :action => "updating Cloud Subnet for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_update_cloud_subnet',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def self.connection_options(cloud_tenant = nil)
    connection_options = {:service => "Network"}
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options
  end

  def self.display_name(number = 1)
    n_('Cloud Subnet (OpenStack)', 'Cloud Subnets (OpenStack)', number)
  end

  private

  def connection_options(cloud_tenant = nil)
    self.class.connection_options(cloud_tenant)
  end
end
