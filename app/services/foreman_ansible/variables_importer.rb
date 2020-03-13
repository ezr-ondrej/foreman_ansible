# frozen_string_literal: true

module ForemanAnsible
  # Methods to transform variable names coming from the proxy into
  # Foreman AnsibleVariable objects
  class VariablesImporter
    include ::ForemanAnsible::ProxyAPI

    VARIABLE_TYPES = {
      'TrueClass' => 'boolean',
      'FalseClass' => 'boolean',
      'Integer' => 'integer',
      'Fixnum' => 'integer',
      'Float' => 'real',
      'Array' => 'array',
      'Hash' => 'hash',
      'String' => 'string'
    }.freeze

    def initialize(proxy = nil)
      @ansible_proxy = proxy
    end

    def import_variable_names(new_roles)
      return import_variables(remote_variables, new_roles) if @ansible_proxy
      import_variables(local_variables, new_roles)
    end

    def import_variables(role_variables, new_roles)
      detect_changes(
        role_variables.map do |role_name, variables|
          next if variables.blank?
          role = import_new_role(role_name, new_roles)
          next if role.blank?
          initialize_variables(variables, role)
        end.select(&:present?).flatten.compact
      )
    end

    def import_new_role(role_name, new_roles)
      role = AnsibleRole.find_by(:name => role_name)
      if role.blank? && new_roles.map(&:name).include?(role_name)
        role = new_roles.find { |r| r.name == role_name }
      end
      role
    end

    def initialize_variables(variables, role)
      variables.map do |variable_name, variable_default|
        variable = AnsibleVariable.find_or_initialize_by(
          :key => variable_name,
          :ansible_role_id => role.id
        )
        variable.assign_attributes(:default_value => variable_default,
                                   :key_type => infer_key_type(variable_default))
        variable.imported = true if variable.new_record?
        variable.valid? ? variable : nil
      end
    end

    def detect_changes(imported)
      changes = {}.with_indifferent_access
      persisted, changes[:new] = imported.partition { |var| var.id.present? }
      changed, _old = persisted.partition(&:changed?)
      changes[:override], changes[:update] = changed.partition(&:override?)
      changes[:obsolete] = AnsibleVariable.where.not(:id => persisted.pluck(:id), :imported => false)
      changes
    end

    def finish_import(new, obsolete, update, override)
      results = { :added => [], :obsolete => [], :updated => [], :overridden => [] }
      results[:added] = create_new_variables(new) if new.present?
      results[:obsolete] = delete_old_variables(obsolete) if obsolete.present?
      results[:updated] = update_variables(update) if update.present?
      results[:overridden] = override_variables(override) if override.present?
      results
    end

    def create_new_variables(variables)
      iterate_over_variables(variables) do |role, memo, attrs|
        variable = AnsibleVariable.new(attrs)
        variable.ansible_role = ::AnsibleRole.find_by(:name => role)
        variable.save
        memo << variable
      end
    end

    def update_variables(variables)
      iterate_over_variables(variables) do |_role, memo, attrs|
        var = AnsibleVariable.find(attrs['id'])
        var.update(attrs)
        memo << var
      end
    end

    def override_variables(variables)
      update_variables(variables).each { |var| var.update(:override => false) }
    end

    def delete_old_variables(variables)
      iterate_over_variables(variables) do |_role, memo, attrs|
        variable = AnsibleVariable.find(attrs['id'])
        memo << variable.key
        variable.destroy
      end
    end

    private

    def local_variables
      ::AnsibleVariable.all
    end

    def remote_variables
      proxy_api.all_variables
    end

    def infer_key_type(value)
      VARIABLE_TYPES[value.class.to_s] || 'string'
    end

    def iterate_over_variables(variables)
      variables.reduce([]) do |memo, (role, vars)|
        vars.each do |_key, attrs|
          yield role, memo,  JSON.parse(attrs)['ansible_variable'] if block_given?
        end
        memo
      end
    end
  end
end
