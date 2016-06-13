# Encoding: utf-8
# Cloud Foundry WebLogic Buildpack
# Copyright 2013-2016 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module JavaBuildpack
  module Container
    module Wls

      # Applies the provided configuration to the installed instance of Weblogic
      class WlsConfigurer
        include JavaBuildpack::Container::Wls::WlsConstants

        def initialize(configuration_map)
          @app_name                 = configuration_map['app_name']
          @application              = configuration_map['application']
          @app_services_config      = configuration_map['app_services_config']
          @app_src_path             = configuration_map['app_src_path']
          @domain_name              = configuration_map['domain_name']
          @domain_home              = configuration_map['domain_home']
          @server_name              = configuration_map['server_name']
          @droplet                  = configuration_map['droplet']
          @java_home                = configuration_map['java_home']
          @config_cache_root        = configuration_map['config_cache_root']
          @wls_sandbox_root         = configuration_map['wls_sandbox_root']
          @wls_home                 = configuration_map['wls_home']
          @wls_install              = configuration_map['wls_install']
          @wls_domain_path          = configuration_map['wls_domain_path']
          @wls_domain_yaml_config   = configuration_map['wls_domain_yaml_config']
          @wls_domain_config_script = configuration_map['wls_domain_config_script']
        end

        # Configure Weblogic
        def configure
          configure_start_time = Time.now
          print "-----> Configuring WebLogic domain under #{@wls_sandbox_root.relative_path_from(@droplet.root)}\n"

          @wls_home = File.dirname(Dir.glob("#{@wls_install}/**/weblogic.jar")[0]) + '/../..'
          unless @wls_home
            log_and_print("Problem with install, check captured install log output at #{@wls_install}/install.log")
          end

          log("WebLogic install is located at : #{@wls_install}")
          log("Application is located at      : #{@application.root}")

          # Save the location of the WLS Domain template jar file - this varies across releases
          # 10.3.6 - under ./wlserver/common/templates/domains/wls.jar
          # 12.1.2 - under ./wlserver/common/templates/wls/wls.jar
          @wls_domain_template_jar = Dir.glob("#{@wls_install}/**/wls.jar")[0]

          # Now add or update the Domain path and Wls Home inside the wlsDomainYamlConfigFile
          update_domain_config_template(@wls_domain_yaml_config)

          # Modify WLS commEnv Script to use -server rather than -client
          # Modify WLS commEnv Script to set MW_HOME variable as this is used in 10.3.x but not set within it.
          modify_comm_env
          log_and_print('Updated the commEnv.sh script to point to correct BEA_HOME, MW_HOME and WL_HOME')

          log_buildpack_config
          log_domain_config

          create_domain
          check_domain
          puts "(#{(Time.now - configure_start_time).duration})"
        end

        private

        BEA_HOME_MW_TEMPLATE    = 'BEA_HOME="\$MW_HOME"'.freeze
        MW_HOME_MW_TEMPLATE     = 'MW_HOME="\$MW_HOME"'.freeze
        BEA_HOME_BLANK_TEMPLATE = 'BEA_HOME=""'.freeze
        MW_HOME_BLANK_TEMPLATE  = 'MW_HOME=""'.freeze

        def update_domain_config_template(wls_domain_yaml_config)
          original = File.open(wls_domain_yaml_config, 'r') { |f| f.read }

          # Remove any existing references to wlsHome or domainPath
          modified = original.gsub(/ *domainName:.*$\n/, '')
          modified = original.gsub(/ *serverName:.*$\n/, '')
          modified = original.gsub(/ *wlsHome:.*$\n/, '')
          modified = original.gsub(/ *wlsDomainTemplateJar:.*$\n/, '')
          modified = modified.gsub(/ *domainPath:.*$\n/, '')
          modified = modified.gsub(/ *appName:.*$\n/, '')
          modified = modified.gsub(/ *appSrcPath:.*$\n/, '')

          # Add new references to wlsHome and domainPath
          modified << "  domainName: #{@domain_name}\n"
          modified << "  serverName: #{@server_name}\n"
          modified << "  wlsHome: #{@wls_home}\n"
          modified << "  wlsDomainTemplateJar: #{@wls_domain_template_jar}\n"
          modified << "  domainPath: #{@wls_domain_path}\n"
          modified << "  appName: #{@app_name}\n"
          modified << "  appSrcPath: #{@app_src_path}\n"

          File.open(wls_domain_yaml_config, 'w') { |f| f.write modified }

          log("Added entry for WLS_HOME to point to #{@wls_home} in domain config file")
          log("Added entry for DOMAIN_PATH to point to #{@wls_domain_path} in domain config file")
        end

        def customize_wls_server_start(start_server_script, additional_params)
          with_additional_entries = additional_params + "\r\n" + WLS_SERVER_START_TOKEN
          original                = File.open(start_server_script, 'r') { |f| f.read }
          modified                = original.gsub(/WLS_SERVER_START_TOKEN/, with_additional_entries)
          File.open(start_server_script, 'w') { |f| f.write modified }

          log("Modified #{start_server_script} with additional parameters: #{additional_params} ")
        end

        def modify_comm_env
          Dir.glob("#{@wls_install}/**/commEnv.sh").each do |commEnvScript|
            original = File.open(commEnvScript, 'r') { |f| f.read }
            modified = original.gsub(/#{CLIENT_VM}/, SERVER_VM)

            updated_bea_home_entry        = "BEA_HOME=\"#{@wls_install}\""
            updated_middleware_home_entry = "MW_HOME=\"#{@wls_install}\""

            modified = modified.gsub(/#{BEA_HOME_MW_TEMPLATE}/, updated_bea_home_entry)
            modified = modified.gsub(/#{MW_HOME_MW_TEMPLATE}/, updated_middleware_home_entry)
            modified = modified.gsub(/#{BEA_HOME_BLANK_TEMPLATE}/, updated_bea_home_entry)
            modified = modified.gsub(/#{MW_HOME_BLANK_TEMPLATE}/, updated_middleware_home_entry)
            File.open(commEnvScript, 'w') { |f| f.write modified }
          end

          log('Modified commEnv.sh files to use \'-server\' vm from the default \'-client\' vm!!')
          log('                      and also added BEA_HOME and MW_HOME variables!!')
        end

        def create_domain
          @wls_complete_domain_configs_yml  = complete_domain_configs_yml

          # Filtered Pathname has a problem with non-existing files. So, get the path as string and add the props file
          # name for the output file
          @wls_complete_domain_configs_props = @wls_domain_yaml_config.to_s.sub('.yml', '.props')

          system "/bin/rm  #{@wls_complete_domain_configs_props} 2>/dev/null"

          # Consolidate all the user defined service definitions provided via the app,
          # along with anything else that comes via the Service Bindings via the environment (VCAP_SERVICES) during
          # staging/execution of the droplet.
          JavaBuildpack::Container::Wls::ServiceBindingsHandler.create_service_definitions_from_file_set(
            @wls_complete_domain_configs_yml,
            @config_cache_root,
            @wls_complete_domain_configs_props)

          JavaBuildpack::Container::Wls::ServiceBindingsHandler.create_service_definitions_from_bindings(
            @app_services_config,
            @wls_complete_domain_configs_props)

          log("Done generating Domain Configuration Property file for WLST: #{@wls_complete_domain_configs_props}")
          log('--------------------------------------')

          # Run wlst.sh to generate the domain as per the requested configurations
          wlst_script = Dir.glob("#{@wls_install}" + '/**/wlst.sh')[0]

          command = "/bin/chmod +x #{wlst_script}; export JAVA_HOME=#{@java_home};"
          command << " export MW_HOME=#{@wls_install}; export WL_HOME=#{@wls_home}; export WLS_HOME=#{@wls_home}; " \
                     'export CLASSPATH=;'
          command << " sed -i.bak 's#JVM_ARGS=\"#JVM_ARGS=\" -Djava.security.egd=file:/dev/./urandom #g' " \
                     "#{wlst_script} 2>/dev/null; "
          command << " #{wlst_script}  #{@wls_domain_config_script} #{@wls_complete_domain_configs_props}"
          command << " > #{@wls_sandbox_root}/wlstDomainCreation.log"

          log("Executing WLST: #{command}")
          system "#{command} "
          log("WLST finished generating domain under #{@domain_home}. WLST log saved at: " \
              "#{@wls_sandbox_root}/wlstDomainCreation.log")

          link_jars_to_domain

          print "-----> Finished configuring WebLogic Domain under #{@domain_home.relative_path_from(@droplet.root)}.\n"
          print "       WLST log saved at: #{@wls_sandbox_root}/wlstDomainCreation.log\n"
        end

        def complete_domain_configs_yml
          # There can be multiple service definitions (for JDBC, JMS, Foreign JMS services)
          # Based on chosen config location, load the related files

          wls_jms_config_files        = Dir.glob("#{@config_cache_root}/#{WLS_JMS_CONFIG_DIR}/*.yml")
          wls_jdbc_config_files       = Dir.glob("#{@config_cache_root}/#{WLS_JDBC_CONFIG_DIR}/*.yml")
          wls_foreign_jms_config_file = Dir.glob("#{@config_cache_root}/#{WLS_FOREIGN_JMS_CONFIG_DIR}/*.yml")

          wls_complete_domain_configs_yml = [@wls_domain_yaml_config]
          wls_complete_domain_configs_yml += wls_jdbc_config_files + wls_jms_config_files + wls_foreign_jms_config_file

          log("Configuration files used for Domain creation: #{wls_complete_domain_configs_yml}")
          wls_complete_domain_configs_yml
        end

        def check_domain
          return if Dir.glob("#{@domain_home}/config/config.xml")[0]

          log_and_print('Problem with domain creation!!')
          system "/bin/cat #{@wls_sandbox_root}/wlstDomainCreation.log"
        end

        def link_jars_to_domain
          log('Linking pre and post jar directories relative to the Domain')

          system '/bin/ln', '-s', "#{@config_cache_root}/#{WLS_PRE_JARS_CACHE_DIR}",
                 "#{@domain_home}/#{WLS_PRE_JARS_CACHE_DIR}", '2>/dev/null'
          system '/bin/ln', '-s', "#{@config_cache_root}/#{WLS_POST_JARS_CACHE_DIR}",
                 "#{@domain_home}/#{WLS_POST_JARS_CACHE_DIR}", '2>/dev/null'
        end

        # Generate the property file based on app bundled configs for test against WLST
        def test_service_creation
          JavaBuildpack::Container::Wls::ServiceBindingsHandler.create_service_definitions_from_file_set(
            @wls_complete_domain_configs_yml,
            @config_cache_root,
            @wls_complete_domain_configs_props)
          JavaBuildpack::Container::Wls::ServiceBindingsHandler.create_service_definitions_from_bindings(
            @app_services_config,
            @wls_complete_domain_configs_props)

          log('Done generating Domain Configuration Property file for WLST: '\
                            "#{@wls_complete_domain_configs_props}")
          log('--------------------------------------')
        end

        def log_domain_config
          log('Configurations for WLS Domain Creation')
          log('--------------------------------------')
          log("  Domain Name                : #{@domain_name}")
          log("  Server Name                : #{@server_name}")
          log("  Domain Location            : #{@domain_home}")
          log("  App Deployment Name        : #{@app_name}")
          log("  App Source Directory       : #{@app_src_path}")
          log("  Using App bundled Config?  : #{@prefer_app_config}")
          log("  Domain creation script     : #{@wls_domain_config_script}")
          log("  Input WLS Yaml Configs     : #{@wls_complete_domain_configs_yml}")
          log("  WLST Input Config          : #{@wls_complete_domain_configs_props}")
          log('--------------------------------------')
        end

        def log_buildpack_config
          log('Configurations for Java WLS Buildpack')
          log('--------------------------------------')
          log("  Sandbox Root  : #{@wls_sandbox_root} ")
          log("  JAVA_HOME     : #{@java_home} ")
          log("  WLS_INSTALL   : #{@wls_install} ")
          log("  WLS_HOME      : #{@wls_home}")
          log("  DOMAIN_NAME   : #{@domain_name}")
          log("  SERVER_NAME   : #{@server_name}")
          log("  DOMAIN HOME   : #{@domain_home}")
          log('--------------------------------------')
        end

        def log(content)
          JavaBuildpack::Container::Wls::WlsUtil.log(content)
        end

        def log_and_print(content)
          JavaBuildpack::Container::Wls::WlsUtil.log_and_print(content)
        end

      end
    end
  end
end
