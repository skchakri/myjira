require "base64"
require "stringio"

module Api
  module V1
    # Ingests media (screenshots, GIF/video screen-recordings) captured during a
    # real browser test run and attaches it to an existing board item. The relay
    # (CLI ⇄ Claude-in-Chrome) is JSON/curl-based and the browser produces base64
    # PNGs / GIFs, so the primary path accepts base64; a multipart path is kept as
    # a fallback for real-file uploaders. The media then surfaces in the
    # per-project "What's New" changelog (which reads the task's image/video
    # attachments).
    #
    # The "only capture on a REAL browser test" guardrail lives in the global
    # myjira-relay skill, not here — this endpoint stays permissive so any genuine
    # runner can attach evidence.
    class TaskAttachmentsController < BaseController
      before_action :find_project!

      def create
        task = @project.tasks.find(params[:task_id])

        blobs = collect_base64_blobs + collect_multipart_blobs
        if blobs.empty?
          render json: {
            error: "no_media",
            message: "Provide attachments as base64 (attachments: [{filename, content_type, data_base64}]) " \
                     "or multipart files (attachments[])."
          }, status: :unprocessable_entity
          return
        end

        # Enforce the model's limits up front. On a *persisted* record `attach`
        # saves immediately, which would slip past the `attachments_within_limits`
        # validation — so gate here before touching the database.
        errors = limit_errors(task, blobs)
        if errors.any?
          render json: { error: "invalid", message: errors.join(", "), details: errors }, status: :unprocessable_entity
          return
        end

        before = task.attachments.map(&:id)
        blobs.each { |b| task.attachments.attach(b) }

        attached = task.reload.attachments.reject { |a| before.include?(a.id) }
        render json: {
          ok: true,
          attached: attached.map { |a| serialize_attachment(a) },
          rejected: @rejected,
          next_steps: next_steps_for(task)
        }, status: :created
      end

      private

      def limit_errors(task, blobs)
        errors = []
        total = task.attachments.size + blobs.size
        errors << "too many files (max #{Task::MAX_ATTACHMENTS})" if total > Task::MAX_ATTACHMENTS
        blobs.each do |b|
          size = blob_size(b)
          next if size <= Task::MAX_ATTACHMENT_SIZE
          name = b.is_a?(Hash) ? b[:filename] : b.original_filename
          errors << "#{name} exceeds #{Task::MAX_ATTACHMENT_SIZE / 1.megabyte} MB"
        end
        errors
      end

      def blob_size(blob)
        if blob.is_a?(Hash)
          blob[:io].size
        else
          blob.size
        end
      end

      # base64 items: { filename:, content_type:, data_base64: } (data: URI prefix tolerated).
      def collect_base64_blobs
        @rejected ||= []
        items = params[:attachments]
        items = items.values if items.respond_to?(:values) && !items.is_a?(Array) # permit hash-of-hashes
        return [] unless items.is_a?(Array)

        items.filter_map do |item|
          next unless item.respond_to?(:[]) && item[:data_base64].present?

          filename = item[:filename].presence || "upload"
          content_type = item[:content_type].presence || infer_content_type(filename)
          bytes = decode_base64(item[:data_base64])
          if bytes.blank?
            @rejected << { filename: filename, reason: "invalid_base64" }
            next
          end
          { io: StringIO.new(bytes), filename: filename, content_type: content_type }
        end
      end

      # multipart fallback: attachments[] uploaded files.
      def collect_multipart_blobs
        files = params[:attachments]
        return [] unless files.is_a?(Array)

        files.select { |f| f.respond_to?(:original_filename) && f.respond_to?(:read) }
      end

      def decode_base64(str)
        cleaned = str.to_s.sub(/\Adata:[^;]*;base64,/, "").strip
        return nil if cleaned.empty?

        Base64.strict_decode64(cleaned)
      rescue ArgumentError
        begin
          Base64.decode64(cleaned)
        rescue StandardError
          nil
        end
      end

      def infer_content_type(filename)
        Marcel::MimeType.for(name: filename) || "application/octet-stream"
      end

      def serialize_attachment(att)
        {
          filename: att.filename.to_s,
          content_type: att.content_type,
          byte_size: att.byte_size,
          url: "#{base_url}#{Rails.application.routes.url_helpers.rails_blob_path(att, only_path: true)}"
        }
      end
    end
  end
end
