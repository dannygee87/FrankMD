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
      chat = RubyLLM.chat(model: model, provider: provider)
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
      # Image generation requires Gemini API key (for Imagen/Nano Banana models)
      # Check both .fed and ENV since image generation is independent of text provider choice
      gemini_key_for_images.present?
    end

    def image_generation_model
      config_instance.get("image_generation_model") || "imagen-4.0-generate-001"
    end

    # Get Gemini key specifically for image generation
    # Unlike text processing, we always want to check ENV as fallback
    # since image generation is independent of text provider configuration
    def gemini_key_for_images
      cfg = config_instance
      # First check .fed, then ENV
      cfg.instance_variable_get(:@values)&.dig("gemini_api_key") ||
        ENV["GEMINI_API_KEY"]
    end

    def image_generation_info
      {
        enabled: image_generation_enabled?,
        model: image_generation_model
      }
    end

    def generate_image(prompt, reference_image_path: nil)
      return { error: "Image generation not configured. Requires Gemini API key." } unless image_generation_enabled?
      return { error: "No prompt provided" } if prompt.blank?

      model = image_generation_model

      # Check for reference image
      reference_image_path_full = nil
      if reference_image_path.present?
        reference_image_path_full = ImagesService.find_image(reference_image_path)
        unless reference_image_path_full&.exist?
          Rails.logger.warn "Reference image not found: #{reference_image_path}"
          reference_image_path_full = nil
        end
      end

      # Use gemini-ai for image-to-image, ruby_llm for text-to-image
      if reference_image_path_full
        generate_image_with_reference(prompt, reference_image_path_full, model)
      else
        generate_image_text_only(prompt, model)
      end
    rescue StandardError => e
      Rails.logger.error "Image generation error: #{e.class} - #{e.message}"
      { error: "Image generation failed: #{e.message}" }
    end

    # Text-to-image generation using Imagen 4 API directly
    def generate_image_text_only(prompt, model)
      require "net/http"
      require "json"

      Rails.logger.info "Image generation (text-only): model=#{model}, prompt_length=#{prompt.length}"

      api_key = gemini_key_for_images
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{model}:predict")

      request_body = {
        instances: [
          { prompt: prompt }
        ],
        parameters: {
          sampleCount: 1,
          aspectRatio: "1:1"
        }
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["x-goog-api-key"] = api_key
      request.body = request_body.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = JSON.parse(response.body) rescue { "error" => response.body }
        error_message = error_body.dig("error", "message") || error_body["error"] || "Unknown error"
        Rails.logger.error "Imagen API error (#{response.code}): #{error_message}"
        return { error: "Imagen API error: #{error_message}" }
      end

      result = JSON.parse(response.body)
      extract_image_from_imagen_response(result, model)
    end

    def extract_image_from_imagen_response(response, model)
      predictions = response["predictions"] || []
      return { error: "No predictions in response" } if predictions.empty?

      prediction = predictions.first
      if prediction["bytesBase64Encoded"]
        {
          data: prediction["bytesBase64Encoded"],
          mime_type: prediction["mimeType"] || "image/png",
          model: model,
          revised_prompt: nil
        }
      else
        { error: "No image data in response" }
      end
    end

    # Image-to-image generation using Nano Banana (Gemini image model)
    def generate_image_with_reference(prompt, reference_image_path, _model)
      require "net/http"
      require "json"
      require "base64"

      # Use Nano Banana Pro model for image-to-image editing
      edit_model = "gemini-3-pro-image-preview"

      Rails.logger.info "Image generation (with reference): model=#{edit_model}, prompt_length=#{prompt.length}, reference=#{reference_image_path}"

      # Read and encode the reference image
      image_data = File.binread(reference_image_path)
      base64_image = Base64.strict_encode64(image_data)
      mime_type = mime_type_for_path(reference_image_path)

      # Build request to Gemini API v1beta endpoint
      api_key = gemini_key_for_images
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{edit_model}:generateContent?key=#{api_key}")

      request_body = {
        contents: [
          {
            role: "user",
            parts: [
              { text: prompt },
              {
                inlineData: {
                  mimeType: mime_type,
                  data: base64_image
                }
              }
            ]
          }
        ],
        generationConfig: {
          responseModalities: [ "TEXT", "IMAGE" ]
        }
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 120  # Image generation can take time

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = request_body.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = JSON.parse(response.body) rescue { "error" => response.body }
        error_message = error_body.dig("error", "message") || error_body["error"] || "Unknown error"
        Rails.logger.error "Gemini API error (#{response.code}): #{error_message}"
        return { error: "Gemini API error: #{error_message}" }
      end

      result = JSON.parse(response.body)
      extract_image_from_gemini_response(result, edit_model)
    end

    def extract_image_from_gemini_response(response, model)
      return { error: "No response from Gemini" } unless response

      # Check for candidates in the response
      candidates = response.dig("candidates") || []
      return { error: "No candidates in response" } if candidates.empty?

      # Look for image parts in the response
      parts = candidates.first&.dig("content", "parts") || []

      parts.each do |part|
        if part["inlineData"]
          return {
            data: part["inlineData"]["data"],
            mime_type: part["inlineData"]["mimeType"] || "image/png",
            model: model,
            revised_prompt: nil
          }
        end
      end

      # If no image found, check for text response (might be an error or description)
      text_parts = parts.select { |p| p["text"] }.map { |p| p["text"] }.join(" ")
      if text_parts.present?
        Rails.logger.warn "Gemini returned text instead of image: #{text_parts.truncate(200)}"
      end

      { error: "No image data in response" }
    end

    def mime_type_for_path(path)
      ext = File.extname(path).downcase
      case ext
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".png" then "image/png"
      when ".gif" then "image/gif"
      when ".webp" then "image/webp"
      else "image/jpeg"
      end
    end

    private

    def configure_image_client
      RubyLLM.configure do |config|
        # Clear all keys first
        config.openai_api_key = nil
        config.openrouter_api_key = nil
        config.anthropic_api_key = nil
        config.gemini_api_key = nil
        config.ollama_api_base = nil

        # Image generation uses Gemini - always check ENV as fallback
        config.gemini_api_key = gemini_key_for_images
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
