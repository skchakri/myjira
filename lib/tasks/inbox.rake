namespace :inbox do
  desc "Print what is waiting on you in the Work Queue; PUSH=1 also sends it as one web push"
  task summary: :environment do
    inbox = WorkQueue::Inbox.new
    puts "Inbox: #{inbox.summary_line}"
    inbox.entries.select { |e| e.flow.waiting_level == "late" }.first(5).each do |e|
      puts "  waiting #{e.flow.waiting_words}: #{WorkQueue::Store.label(e.item.slug)} ##{e.item.n} #{e.item.title.truncate(80)}"
    end
    next unless ENV["PUSH"] == "1"

    if inbox.empty?
      puts "Push: skipped, nothing is waiting"
    elsif !WebPushNotifier.vapid_configured?
      puts "Push: skipped, VAPID keys are not set"
    else
      sent = WebPushNotifier.deliver(title: "myjira inbox", body: inbox.summary_line, url: "#{WebPushNotifier.base_url}/inbox")
      puts "Push: sent to #{sent} #{'browser'.pluralize(sent)}"
    end
  end
end
