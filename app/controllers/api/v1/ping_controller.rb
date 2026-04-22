module Api
  module V1
    class PingController < BaseController
      def show
        render json: { ok: true, service: "myjira", version: "0.1.0", time: Time.current.iso8601 }
      end
    end
  end
end
