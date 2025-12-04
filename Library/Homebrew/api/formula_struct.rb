# typed: strict
# frozen_string_literal: true

require "service"
require "utils/spdx"

module Homebrew
  module API
    class FormulaStruct < T::Struct
      PREDICATES = T.let({
        bottle:              ["bottle"],
        deprecated:          ["deprecation_date"],
        disabled:            ["disable_date"],
        head:                ["urls", "head"],
        keg_only:            ["keg_only_reason"],
        no_autobump_message: ["no_autobump_message"],
        pour_bottle:         ["pour_bottle_only_if"],
        service:             ["service"],
        stable:              ["urls", "stable"],
      }.freeze, T::Hash[Symbol, T::Array[String]])

      DeprecateDisableArgs = T.type_alias do
        {
          date:                String,
          because:             T.nilable(T.any(String, Symbol)),
          replacement_formula: T.nilable(String),
          replacement_cask:    T.nilable(String),
        }
      end

      DependencyArgs = T.type_alias do
        T.any(
          # Formula name: "foo"
          String,
          # Formula name and dependency type: { "foo" => :build }
          T::Hash[String, Symbol],
        )
      end

      RequirementArgs = T.type_alias do
        T.any(
          # Requirement name: :macos
          Symbol,
          # Requirement name and other info: { macos: :build }
          T::Hash[Symbol, T::Array[T.anything]],
        )
      end

      UsesFromMacOSArgs = T.type_alias do
        [
          T.any(
            # Formula name: "foo"
            String,
            # Formula name and dependency type: { "foo" => :build }
            # Formula name, dependency type, and version bounds: { "foo" => :build, since: :catalina }
            T::Hash[T.any(String, Symbol), T.any(Symbol, T::Array[Symbol])],
          ),
          # If the first argument is only a name, this argument contains the version bounds: { since: :catalina }
          T::Hash[Symbol, Symbol],
        ]
      end

      # `:codesign` and custom requirement classes are not supported.
      API_SUPPORTED_REQUIREMENTS = [:arch, :linux, :macos, :maximum_macos, :xcode].freeze
      private_constant :API_SUPPORTED_REQUIREMENTS

      sig { params(hash: T::Hash[String, T.untyped]).returns(FormulaStruct) }
      def self.from_hash(hash)
        if (caveats = hash["caveats"])
          hash["caveats"] = Formulary.replace_placeholders(caveats)
        end

        hash["bottle_checksums"] = begin
          files = hash.dig("bottle", "stable", "files") || {}
          files.map do |tag, bottle_spec|
            {
              cellar: Formulary.convert_to_string_or_symbol(bottle_spec.fetch("cellar")),
              tag.to_sym => bottle_spec.fetch("sha256"),
            }
          end
        end

        hash["bottle_rebuild"] = hash.dig("bottle", "stable", "rebuild")

        conflicts_with = hash["conflicts_with"] || []
        conflicts_with_reasons = hash["conflicts_with_reasons"] || []
        hash["conflicts"] = conflicts_with.zip(conflicts_with_reasons).map do |name, because|
          [name, { because: }]
        end

        if (deprecation_date = hash["deprecation_date"])
          hash["deprecate_args"] = {
            date:                deprecation_date,
            because:             DeprecateDisable.to_reason_string_or_symbol(hash["deprecation_reason"],
                                                                             type: :formula),
            replacement_formula: hash["deprecation_replacement_formula"],
            replacement_cask:    hash["deprecation_replacement_cask"],
          }
        end

        if (disable_date = hash["disable_date"])
          hash["disable_args"] = {
            date:                disable_date,
            because:             DeprecateDisable.to_reason_string_or_symbol(hash["disable_reason"], type: :formula),
            replacement_formula: hash["disable_replacement_formula"],
            replacement_cask:    hash["disable_replacement_cask"],
          }
        end

        hash["head_dependency_hash"] = hash["head_dependencies"]

        hash["head_url_args"] = begin
          url = hash.dig("urls", "head", "url")
          specs = {
            branch: hash.dig("urls", "head", "branch"),
            using:  hash.dig("urls", "head", "using")&.to_sym,
          }.compact_blank
          [url, specs]
        end

        if (keg_only_hash = hash["keg_only_reason"])
          reason = Formulary.convert_to_string_or_symbol(keg_only_hash.fetch("reason"))
          explanation = keg_only_hash.fetch("explanation")
          hash["keg_only_args"] = [reason, explanation]
        end

        hash["license"] = SPDX.string_to_license_expression(hash["license"])

        hash["link_overwrite_paths"] = hash["link_overwrite"]

        if (reason = hash["no_autobump_message"])
          reason = reason.to_sym if NO_AUTOBUMP_REASONS_LIST.key?(reason.to_sym)
          hash["no_autobump_args"] = { because: reason }
        end

        if (condition = hash["pour_bottle_only_if"])
          hash["pour_bottle_args"] = { only_if: condition.to_sym }
        end

        hash["requirements_array"] = hash["requirements"]

        hash["ruby_source_checksum"] = hash.dig("ruby_source_checksum", "sha256")

        if (service_hash = hash["service"])
          service_hash = Homebrew::Service.from_hash(service_hash)

          hash["service_run_args"], hash["service_run_kwargs"] = case service_hash[:run]
          when Hash
            [[], service_hash[:run]]
          when Array, String
            [Array(service_hash[:run]), {}]
          end

          hash["service_name_args"] = hash.dig("service", "name")

          hash["service_args"] = hash["service"]&.filter do |key, _|
            key != "name" && key != "run"
          end
        end

        hash["stable_checksum"] = hash.dig("urls", "stable", "checksum")

        hash["stable_dependency_hash"] = {
          "dependencies"             => hash["dependencies"] || [],
          "build_dependencies"       => hash["build_dependencies"] || [],
          "test_dependencies"        => hash["test_dependencies"] || [],
          "recommended_dependencies" => hash["recommended_dependencies"] || [],
          "optional_dependencies"    => hash["optional_dependencies"] || [],
          "uses_from_macos"          => hash["uses_from_macos"] || [],
          "uses_from_macos_bounds"   => hash["uses_from_macos_bounds"] || [],
        }

        hash["stable_url_args"] = begin
          url = hash.dig("urls", "stable", "url")
          specs = {
            tag:      hash.dig("urls", "stable", "tag"),
            revision: hash.dig("urls", "stable", "revision"),
            using:    hash.dig("urls", "stable", "using")&.to_sym,
          }.compact_blank
          [url, specs]
        end

        hash["stable_version"] = hash.dig("versions", "stable")

        PREDICATES.each do |predicate_name, json_keys|
          hash["#{predicate_name}_present"] = hash.dig(*json_keys).present?
        end

        super
      end

      PREDICATES.each_key do |predicate_name|
        present_method_name = :"#{predicate_name}_present"
        predicate_method_name = :"#{predicate_name}?"

        const present_method_name, T::Boolean, default: false

        define_method(predicate_method_name) do
          send(present_method_name)
        end
      end

      const :aliases, T::Array[String], default: []
      const :bottle, T::Hash[String, T.untyped], default: {}
      const :bottle_checksums, T::Array[T::Hash[String, T.anything]], default: []
      const :bottle_rebuild, Integer, default: 0
      const :caveats, T.nilable(String)
      const :conflicts, T::Array[[String, { because: T.nilable(String) }]], default: []
      const :deprecate_args, T.nilable(DeprecateDisableArgs)
      const :desc, String
      const :disable_args, T.nilable(DeprecateDisableArgs)
      const :head_url_args, [String, T::Hash[Symbol, T.anything]]
      const :homepage, String
      const :keg_only_args, T.nilable([T.any(String, Symbol), String])
      const :license, SPDX::LicenseExpression
      const :link_overwrite_paths, T::Array[String], default: []
      const :no_autobump_args, T.nilable({ because: T.any(String, Symbol) })
      const :oldnames, T.nilable(T::Array[String])
      const :post_install_defined, T::Boolean, default: false
      const :pour_bottle_args, T.nilable({ only_if: Symbol })
      const :revision, Integer, default: 0
      const :ruby_source_checksum, String
      const :ruby_source_path, String
      const :service_args, T::Array[[Symbol, BasicObject]], default: []
      const :service_name_args, T::Hash[Symbol, String], default: {}
      const :service_run_args, T::Array[Homebrew::Service::RunParam], default: []
      const :service_run_kwargs, T::Hash[Symbol, Homebrew::Service::RunParam], default: {}
      const :stable_checksum, T.nilable(String)
      const :stable_url_args, [String, T::Hash[Symbol, T.anything]]
      const :stable_version, String
      const :tap_git_head, String
      const :version_scheme, Integer, default: 0
      const :versioned_formulae, T::Array[String], default: []

      sig { returns(T::Array[T.any(DependencyArgs, RequirementArgs)]) }
      def head_dependencies
        spec_dependencies(:head) + spec_requirements(:head)
      end

      sig { returns(T::Array[T.any(DependencyArgs, RequirementArgs)]) }
      def stable_dependencies
        spec_dependencies(:stable) + spec_requirements(:stable)
      end

      sig { returns(T::Array[UsesFromMacOSArgs]) }
      def head_uses_from_macos
        spec_uses_from_macos(:head)
      end

      sig { returns(T::Array[UsesFromMacOSArgs]) }
      def stable_uses_from_macos
        spec_uses_from_macos(:stable)
      end

      private

      const :stable_dependency_hash, T::Hash[String, T::Array[String]], default: {}
      const :head_dependency_hash, T::Hash[String, T::Array[String]], default: {}
      const :requirements_array, T::Array[T::Hash[String, T.untyped]], default: []

      sig { params(spec: Symbol).returns(T::Array[DependencyArgs]) }
      def spec_dependencies(spec)
        deps_hash = send("#{spec}_dependency_hash")
        dependencies = deps_hash.fetch("dependencies", [])
        dependencies + [:build, :test, :recommended, :optional].filter_map do |type|
          deps_hash["#{type}_dependencies"]&.map do |dep|
            { dep => type }
          end
        end.flatten(1)
      end

      sig { params(spec: Symbol).returns(T::Array[UsesFromMacOSArgs]) }
      def spec_uses_from_macos(spec)
        deps_hash = send("#{spec}_dependency_hash")
        zipped_array = deps_hash["uses_from_macos"]&.zip(deps_hash["uses_from_macos_bounds"])
        return [] unless zipped_array

        zipped_array.map do |entry, bounds|
          bounds ||= {}
          bounds = bounds.transform_keys(&:to_sym).transform_values(&:to_sym)

          if entry.is_a?(Hash)
            # The key is the dependency name, the value is the dep type. Only the type should be a symbol
            entry = entry.deep_transform_values(&:to_sym)
            # When passing both a dep type and bounds, uses_from_macos expects them both in the first argument
            entry = entry.merge(bounds)
            [entry, {}]
          else
            [entry, bounds]
          end
        end
      end

      sig { params(spec: Symbol).returns(T::Array[RequirementArgs]) }
      def spec_requirements(spec)
        requirements_array.filter_map do |req|
          next unless req["specs"].include?(spec.to_s)

          req_name = req["name"].to_sym
          next if API_SUPPORTED_REQUIREMENTS.exclude?(req_name)

          req_version = case req_name
          when :arch
            req["version"]&.to_sym
          when :macos, :maximum_macos
            MacOSVersion::SYMBOLS.key(req["version"])
          else
            req["version"]
          end

          req_tags = []
          req_tags << req_version if req_version.present?
          req_tags += req["contexts"]&.map do |tag|
            case tag
            when String
              tag.to_sym
            when Hash
              tag.deep_transform_keys(&:to_sym)
            else
              tag
            end
          end

          if req_tags.empty?
            req_name
          else
            { req_name => req_tags }
          end
        end
      end
    end
  end
end
