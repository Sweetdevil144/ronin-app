# frozen_string_literal: true
require 'types'

module Types
  module Spider
    # The type of web spider targets
    TargetType = Types::String.enum('host', 'domain', 'site')

    # Represents a list of hosts.
    HostList = Types::CommaSeparatedList

    # Represents a comma separated list of ports.
    PortList = Types::Array.of(Types::Integer).constructor do |value|
      value.split(/(?:,\s*|\s+)/).map(&:to_i)
    end

    # Represents a list of URLs.
    URLList = Types::CommaSeparatedList

    # Represents a list of file exts.
    ExtList = Types::CommaSeparatedList
  end
end
