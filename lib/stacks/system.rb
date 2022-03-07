class Stacks::System
  class << self
    QBO_NOTES_FORECAST_MAPPING_BEARER = "automator:forecast_mapping:"
    QBO_NOTES_PAYMENT_TERM_BEARER = "automator:payment_term:"
    DEFAULT_PAYMENT_TERM = 15
    DEFAULT_CUSTOMER_MEMO = <<~HEREDOC
      EIN: 47-2941554
      W9: https://w9.sanctuary.computer

      WIRE:
      Sanctuary Computer Inc
      EIN: 47-2941554
      Rou #: 021000021
      Acc #: 685028396

      Chase Bank:
      405 Lexington Ave
      New York, NY 10174

      QUICKPAY:
      admin@sanctuarycomputer.com

      BILL.COM:
      admin@sanctuarycomputer.com
    HEREDOC
  end
end
