# frozen_string_literal: true

require "ruby_llm"

class AiService
  GRAMMAR_PROMPT = <<~PROMPT
    You are a grammar and spelling corrector. Fix ONLY:
    - Grammar errors
    - Spelling mistakes
    - Typos
    - Punctuation errors

    DO NOT change:
    - Facts, opinions, or meaning
    - Writing style or tone
    - Markdown formatting (headers, links, code blocks, lists, etc.)
    - Technical terms or proper nouns
    - Code blocks or inline code

    Return ONLY the corrected text with no explanations or commentary.
  PROMPT

  class << self
    def enabled?
      config_instance.feature_available?("ai")
    end

    def available_providers
      config_instance.ai_providers_available
    end

    def current_provider
      config_instance.effective_ai_provider
    end

    def current_model
      config_instance.effective_ai_model
    end

    def fix_grammar(text)
      return { error: "AI not configured" } unless enabled?
      return { error: "No text provided" } if text.blank?

      provider = current_provider
      model = current_model

      return { error: "No AI provider available" } unless provider && model

      # Debug: log what we're about to use
      cfg = config_instance
      key_for_provider = case provider
      when "openai" then cfg.get_ai("openai_api_key")
      when "openrouter" then cfg.get_ai("openrouter_api_key")
      when "anthropic" then cfg.get_ai("anthropic_api_key")
      when "gemini" then cfg.get_ai("gemini_api_key")
      else nil
      end
      key_prefix = key_for_provider&.slice(0, 10) || "none"
      Rails.logger.info "AI request: provider=#{provider}, model=#{model}, key_prefix=#{key_prefix}..., ai_in_file=#{cfg.ai_configured_in_file?}"

      configure_client
      chat = RubyLLM.chat(model: model, provider: provider.to_sym, assume_model_exists: provider == "ollama")
      chat.with_instructions(GRAMMAR_PROMPT)
      response = chat.ask(text)

      { corrected: response.content, provider: provider, model: model }
    rescue StandardError => e
      Rails.logger.error "AI error (#{provider}/#{model}): #{e.class} - #{e.message}"
      { error: "AI processing failed: #{e.message}" }
    end

    # Get provider info for frontend display
    def provider_info
      {
        enabled: enabled?,
        provider: current_provider,
        model: current_model,
        available_providers: available_providers
      }
    end

    # === Image Generation ===

    def image_generation_enabled?
      # Image generation uses RubyLLM + OpenRouter (Gemini model)
      # Check both .fed and ENV since image generation is independent of text provider choice
      openrouter_key_for_images.present?
    end

    def image_generation_model
      config_instance.get("image_generation_model") || "google/gemini-3.1-flash-image-preview"
    end

    # Get OpenRouter key specifically for image generation
    # Unlike text processing, we always want to check ENV as fallback
    # since image generation is independent of text provider configuration
    def openrouter_key_for_images
      cfg = config_instance
      # First check .fed, then ENV (bypasses get_ai which ignores ENV when any AI key is in .fed)
      cfg.instance_variable_get(:@values)&.dig("openrouter_api_key") ||
        ENV["OPENROUTER_API_KEY"]
    end

    def image_generation_info
      {
        enabled: image_generation_enabled?,
        model: image_generation_model
      }
    end

    def generate_image(prompt, reference_image_path: nil)
      return { error: "Image generation not configured. Requires OpenRouter API key." } unless image_generation_enabled?
      return { error: "No prompt provided" } if prompt.blank?

      model = image_generation_model

      # Resolve reference image if provided
      reference_image_path_full = nil
      if reference_image_path.present?
        reference_image_path_full = ImagesService.find_image(reference_image_path)
        unless reference_image_path_full&.exist?
          Rails.logger.warn "Reference image not found: #{reference_image_path}"
          reference_image_path_full = nil
        end
      end

      Rails.logger.info "Image generation: model=#{model}, prompt_length=#{prompt.length}, reference=#{reference_image_path_full.present?}"

      configure_image_client
      chat = RubyLLM.chat(model: model, provider: :openrouter)
      chat.with_params(modalities: %w[text image])

      content = build_image_content(prompt, reference_image_path_full)
      response = chat.ask(content)

      extract_image_from_response(response, model)
    rescue StandardError => e
      Rails.logger.error "Image generation error: #{e.class} - #{e.message}"
      { error: "Image generation failed: #{e.message}" }
    end

    def extract_image_from_response(response, model)
      content = response.content

      if content.is_a?(RubyLLM::Content) && content.attachments.any?
        attachment = content.attachments.first
        {
          data: Base64.strict_encode64(attachment.content),
          mime_type: attachment.mime_type || "image/png",
          model: model,
          revised_prompt: nil
        }
      else
        text = content.is_a?(RubyLLM::Content) ? content.text : content.to_s
        if text.present?
          Rails.logger.warn "Image model returned text instead of image: #{text.truncate(200)}"
        end
        { error: "No image data in response" }
      end
    end

    private

    def build_image_content(prompt, reference_image_path)
      return prompt unless reference_image_path

      content = RubyLLM::Content.new(prompt)
      content.add_attachment(reference_image_path.to_s)
      content
    end

    def configure_image_client
      RubyLLM.configure do |config|
        # Clear all keys first
        config.openai_api_key = nil
        config.openrouter_api_key = nil
        config.anthropic_api_key = nil
        config.gemini_api_key = nil
        config.ollama_api_base = nil

        # Image generation uses OpenRouter
        config.openrouter_api_key = openrouter_key_for_images
      end
    end

    def configure_client
      cfg = config_instance
      provider = current_provider

      RubyLLM.configure do |config|
        # Clear ALL provider keys first to avoid cross-contamination
        # RubyLLM.configure is additive, so previous keys may persist
        config.openai_api_key = nil
        config.openrouter_api_key = nil
        config.anthropic_api_key = nil
        config.gemini_api_key = nil
        config.ollama_api_base = nil

        # Now set ONLY the specific provider we're using
        # Use get_ai to respect .fed override of ENV vars
        case provider
        when "ollama"
          config.ollama_api_base = cfg.get_ai("ollama_api_base")
        when "openrouter"
          config.openrouter_api_key = cfg.get_ai("openrouter_api_key")
        when "anthropic"
          config.anthropic_api_key = cfg.get_ai("anthropic_api_key")
        when "gemini"
          config.gemini_api_key = cfg.get_ai("gemini_api_key")
        when "openai"
          config.openai_api_key = cfg.get_ai("openai_api_key")
        end
      end
    end

    def config_instance
      # Don't cache - config may change
      Config.new
    end
  end
end
