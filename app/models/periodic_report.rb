# TODO: Add Deel Person to the Data Integrity thing
# TODO: Don't sync to QBO unless payable items are payable!
# TODO: Why no Conan?
# TODO: Why Parker?
# TODO: Don't generate profit shares for amount: 0!
# TODO: Ensure Surplus Calcs work https://stacks.garden3d.net/admin/invoice_passes/669/invoice_trackers/1367

class PeriodicReport < ApplicationRecord
  validates :period_gradation, presence: true
  validates :period_starts_at, presence: true, uniqueness: { scope: [:period_gradation] }
  validates :period_label, presence: true
  has_many :profit_shares, dependent: :destroy

  enum period_gradation: {
    year: 0,
    month: 1,
    quarter: 2,
    trailing_3_months: 3,
    trailing_4_months: 4,
    trailing_6_months: 5,
    trailing_12_months: 6
  }

  def self.create_for_period(period = Stacks::Period.new("Q4, 2025", Date.today.last_quarter.beginning_of_quarter, Date.today.last_quarter.end_of_quarter, :quarter))
    create!(
      period_gradation: period.gradation,
      period_starts_at: period.starts_at,
      period_label: period.label
    )
  end

  def yearly_tenure_multiplier
    @_yearly_tenure_multiplier ||= 0.25
  end

  def period
    @_period ||= Stacks::Period.new(period_label, period_starts_at, period_starts_at.end_of_quarter, period_gradation)
  end

  def display_name
    period_label
  end

  def invoice_passes
    @_invoice_passes ||= InvoicePass.includes(:invoice_trackers).where(start_of_month: period.starts_at..period.ends_at)
  end

  def invoice_trackers
    @_invoice_trackers ||= invoice_passes.map(&:invoice_trackers).flatten
  end

  def surplus
    @_surplus ||= invoice_trackers.map(&:surplus).flatten.reduce(&:+)
  end

  def contributors
    @_contributors ||= Contributor.includes(:forecast_person, :deel_person, :contributor_payouts, :misc_payments, :reimbursements, :trueups).all
  end

  def garden3d_snapshot
    @_garden3d_snapshot ||= Studio.garden3d.snapshot["quarter"].find{|p| p["label"] == period.label}
  end

  def tentative_profit_shares_by_contributor
    @_tentative_profit_shares_by_contributor ||= contributors.reduce({}) do |acc, contributor|
      ledger = contributor.new_deal_ledger_items(false, nil, period.ends_at + 1.day)
      next acc unless ledger[:all].any?

      attendance = ledger[:by_month].select{|p| p.starts_at >= period.starts_at && p.ends_at <= period.ends_at }.reduce({}) do |agg, tuple|
        period, metadata = tuple
        m = metadata.dup
        m.delete(:items)
        agg[period.label] = m
        agg
      end
      next acc if attendance.empty?

      us_cost_of_living_data = PeriodicReport.parsed_numbeo_cost_of_living_indices_by_country["United States"]
      cost_of_living_data = nil
      begin
        # Overrides
        if ["hugh@sanctuary.computer"].include?(contributor.forecast_person.email.downcase)
          cost_of_living_data = us_cost_of_living_data
        else
          country_code = contributor.deel_person.data["addresses"].first.dig("country")
          if country_code == "US"
            cost_of_living_data = us_cost_of_living_data
          else
            country = ISO3166::Country[country_code]
            _, cost_of_living_data = PeriodicReport.parsed_numbeo_cost_of_living_indices_by_country.find{|k, v| country.iso_long_name.include?(k) || country.iso_short_name.include?(k) }
          end
        end
      rescue => e
        # TODO: Raise?
        raise "Could not find cost of living data for #{contributor.forecast_person.email}"
      end

      psu = ledger[:by_month].values.select{|l| l[:elevated_service]}.count
      acc[contributor] = {
        contributor_id: contributor.id,
        email: contributor.forecast_person.email,
        cost_of_living_data: cost_of_living_data,
        psu: psu,
        tenure_multiplier: (psu / 12) * yearly_tenure_multiplier,
        attendance: attendance,
        elevated_service_months: attendance.values.select{|v| v[:elevated_service]}.count,
        shares: 100, # TODO: Calculate this
      }

      acc
    end
  end

  def all_profit_shares_accepted?
    profit_shares.all?(&:accepted?)
  end

  def sync_profit_shares!
    return if profit_shares.any? && all_profit_shares_accepted?

    successful_projects = garden3d_snapshot.dig("accrual", "datapoints", "successful_projects", "value") || 0
    gross_surplus = surplus
    net_profit_share_pool = gross_surplus * 0.3 * (successful_projects / 100.0)
    total_shares = tentative_profit_shares_by_contributor.values.map{|d| d[:shares]}.reduce(&:+) || 0

    ActiveRecord::Base.transaction do
      profit_shares_by_contributor = profit_shares.with_deleted.reduce({}) do |acc, profit_share|
        acc[profit_share.contributor_id] = profit_share
        acc
      end

      touched = []
      tentative_profit_shares_by_contributor.each do |contributor, data|
        profit_share = profit_shares_by_contributor[contributor.id] || ProfitShare.create!({
          periodic_report: self,
          contributor: contributor,
          amount: 0,
          blueprint: {},
        })
        amount = (data[:shares] / total_shares.to_f) * net_profit_share_pool
        if profit_share.amount > 0 && profit_share.amount != amount
          profit_share.update!(accepted_at: nil)
        end
        profit_share.update!(amount: amount, blueprint: data)
        profit_share.restore! if profit_share.deleted?
        touched << profit_share
      end

      to_delete = (profit_shares - touched)
      to_delete.each(&:destroy_fully!)
    end

    update!(blueprint: {
      "generated_at" => DateTime.now.to_s,
      "successful_projects" => successful_projects,
      "gross_surplus" => gross_surplus,
      "net_profit_share_pool" => net_profit_share_pool,
      "total_shares" => total_shares
    })
  end

  def self.parsed_numbeo_cost_of_living_indices_by_country
    raw_numbeo_cost_of_living_indices.split("\n").map do |line|
      line.split("\t").map(&:strip)
    end.reduce({}) do |acc, line|
      acc[line[1]] = {
        country: line[1],
        cost_of_living_index: line[2],
        rent_index: line[3],
        cost_of_living_plus_rent_index: line[4],
        groceries_index: line[5],
        restaurant_price_index: line[6],
        local_purchasing_power_index: line[7],
        overall_rank: line[0],
      }
      acc
    end
  end

  # Copied/pasted raw from here: https://www.numbeo.com/cost-of-living/rankings_by_country.jsp
  def self.raw_numbeo_cost_of_living_indices
    <<~EOF
1	Bermuda	135.8	108.2	123.5	143.4	147.5	101.3
2	Cayman Islands	115.6	76.1	97.9	124.0	101.5	149.6
3	Us Virgin Islands	111.3	46.8	82.5	127.4	94.8	89.8
4	Switzerland	110.7	51.5	84.3	109.7	111.3	170.6
5	Solomon Islands	102.3	19.5	65.4	64.8	46.0	12.6
6	Bahamas	98.8	50.2	77.1	100.9	109.0	57.1
7	Iceland	97.2	49.5	75.9	104.5	104.9	113.7
8	Jersey	88.7	52.4	72.5	79.0	102.3	103.4
9	Singapore	87.7	73.1	81.2	77.3	55.5	105.5
10	Norway	83.7	29.2	59.4	85.4	88.6	124.7
11	Israel	79.7	31.2	58.0	74.0	89.9	119.6
12	Denmark	78.9	28.9	56.6	72.7	93.7	146.6
13	Luxembourg	78.0	49.3	65.2	77.7	83.3	160.5
14	Grenada	76.4	15.8	49.4	68.9	53.5	34.6
15	Hong Kong (China)	75.2	63.1	69.8	75.1	51.1	91.6
16	Isle Of Man	74.7	32.0	55.7	65.3	91.8	116.6
17	Guernsey	73.4	55.3	65.3	77.9	71.2	132.8
18	Netherlands	73.4	38.7	57.9	66.9	81.6	131.9
19	Austria	71.3	25.1	50.7	72.6	71.5	120.0
20	Ireland	70.6	43.8	58.7	68.8	76.6	114.4
21	Gibraltar	70.3	56.0	63.9	60.8	78.7	86.1
22	Finland	69.0	21.9	48.0	68.7	74.1	129.4
23	United States	68.8	40.7	56.3	74.0	72.8	146.0
24	Germany	68.7	24.6	49.0	64.9	66.9	138.3
25	Belgium	68.6	23.8	48.6	66.4	80.7	124.2
26	Sweden	68.0	22.6	47.8	68.4	70.8	133.5
27	Australia	67.9	33.7	52.7	76.5	65.6	137.3
28	United Kingdom	67.8	32.1	51.9	62.8	72.9	122.6
29	France	67.7	22.3	47.5	73.2	66.2	118.5
30	Seychelles	64.5	27.6	48.0	74.8	66.2	34.3
31	Canada	63.0	31.5	48.9	69.6	64.1	119.4
32	Puerto Rico	62.6	21.7	44.3	67.3	56.4	115.9
33	South Korea	61.6	16.1	41.3	77.5	35.8	111.5
34	Italy	61.4	20.5	43.1	62.7	64.7	89.2
35	Macao (China)	60.5	28.5	46.3	67.5	44.3	85.4
36	New Zealand	60.3	26.2	45.0	65.4	59.3	123.8
37	Estonia	59.7	16.7	40.5	54.1	64.9	88.3
38	Cyprus	58.8	26.9	44.6	54.5	60.9	87.7
39	Malta	56.8	28.2	44.1	55.9	64.1	81.1
40	Uruguay	55.6	14.7	37.3	55.1	59.6	55.1
41	United Arab Emirates	55.2	39.6	48.2	44.4	56.5	126.4
42	Andorra	55.1	32.8	45.2	51.4	56.1	126.1
43	Jamaica	54.5	19.2	38.7	63.5	46.8	35.4
44	Slovenia	54.1	20.6	39.1	52.4	51.3	87.5
45	Greece	54.0	13.7	36.0	51.0	59.2	64.1
46	Yemen	53.1	5.9	32.0	64.7	38.2	18.2
47	Czech Republic	53.0	20.7	38.6	50.5	43.1	91.4
48	Costa Rica	52.9	20.3	38.3	59.2	47.5	49.5
49	Croatia	52.4	18.0	37.1	48.9	55.3	86.5
50	Latvia	52.3	11.9	34.3	47.5	54.6	77.7
51	Trinidad And Tobago	52.0	14.4	35.2	55.3	47.4	48.6
52	Spain	51.6	23.2	39.0	50.6	55.1	104.4
53	Lithuania	51.2	15.6	35.3	46.3	56.3	87.6
54	Guyana	50.4	24.8	39.0	62.6	53.8	52.1
55	Qatar	50.4	40.0	45.8	41.6	55.4	153.1
56	Democratic Republic of the Congo	50.2	32.8	42.4	48.0	66.1	26.3
57	Taiwan	49.7	14.2	33.9	64.6	27.4	98.9
58	Slovakia	49.6	17.3	35.2	50.0	43.3	78.1
59	Maldives	48.9	24.6	38.1	52.7	42.9	46.2
60	Portugal	48.8	25.2	38.3	46.9	45.6	66.4
61	Senegal	48.5	19.3	35.5	45.0	42.9	22.2
62	Brunei	48.2	15.5	33.6	66.1	33.3	134.4
63	Palestine	48.1	9.6	30.9	49.8	38.8	49.0
64	Bahrain	47.6	21.4	35.9	45.2	47.0	119.3
65	Papua New Guinea	47.5	29.0	39.2	54.1	34.9	20.2
66	Japan	47.5	14.7	32.8	56.8	30.3	118.3
67	Poland	47.3	18.4	34.4	41.1	48.1	97.1
68	Hungary	46.9	14.1	32.3	45.4	44.7	78.4
69	Belize	46.9	13.6	32.0	52.6	39.3	67.6
70	Cape Verde	46.3	8.8	29.6	57.2	35.6	21.3
71	Albania	45.8	14.1	31.7	46.2	43.5	45.6
72	Panama	45.5	23.2	35.6	51.3	42.9	44.2
73	Ivory Coast	44.8	21.8	34.5	41.3	39.1	12.7
74	Saudi Arabia	43.9	13.5	30.4	41.2	34.5	132.8
75	Oman	43.6	13.2	30.0	42.4	41.8	152.7
76	Montenegro	42.7	16.6	31.0	40.5	44.8	65.1
77	Serbia	42.6	13.1	29.5	39.1	42.2	63.2
78	Mexico	42.6	17.8	31.5	46.6	43.6	48.4
79	Kuwait	42.5	22.0	33.3	35.8	43.4	176.6
80	Angola	42.3	24.8	34.5	39.2	35.0	200.8
81	Suriname	42.3	10.7	28.2	51.5	39.9	19.3
82	Cuba	41.8	11.4	28.3	41.2	26.3	2.4
83	Ethiopia	41.8	18.3	31.3	44.5	22.9	12.5
84	Lebanon	41.7	14.3	29.5	34.4	44.2	37.4
85	Bulgaria	41.6	11.1	28.0	42.6	42.6	84.1
86	Argentina	41.3	12.1	28.3	41.1	47.9	47.5
87	Armenia	40.9	15.2	29.5	36.1	40.3	41.4
88	Cameroon	40.7	19.1	31.1	37.8	45.5	10.5
89	Romania	40.6	12.0	27.8	39.0	43.5	76.8
90	Guatemala	40.4	16.0	29.5	45.1	38.8	37.8
91	El Salvador	39.6	16.6	29.4	42.5	34.4	32.1
92	Jordan	39.4	7.9	25.3	36.3	40.7	54.3
93	Turkey	39.2	13.3	27.6	39.1	37.1	72.8
94	Chile	39.0	11.6	26.8	42.1	39.7	52.8
95	Bosnia And Herzegovina	38.7	8.1	25.0	39.0	32.1	66.9
96	Mauritius	38.3	10.9	26.1	41.1	32.5	55.1
97	Dominican Republic	38.2	14.0	27.4	38.9	35.9	38.6
98	Thailand	38.0	13.9	27.2	44.4	25.0	45.5
99	Myanmar	38.0	11.1	26.0	38.2	16.3	19.8
100	Venezuela	37.7	7.1	24.0	42.2	40.7	17.4
101	South Africa	37.1	13.0	26.4	32.6	35.6	109.2
102	Mozambique	36.9	12.2	25.9	34.1	35.1	30.9
103	Honduras	36.6	12.1	25.7	39.8	34.1	41.3
104	Russia	36.5	12.3	25.7	35.7	35.4	61.6
105	Namibia	36.3	14.2	26.4	37.8	29.6	73.4
106	Zimbabwe	35.9	9.6	24.2	35.0	33.8	27.6
107	Moldova	35.8	14.7	26.4	33.6	32.5	54.1
108	North Macedonia	35.5	7.9	23.2	34.9	29.1	64.9
109	Cambodia	34.8	10.0	23.7	41.6	25.4	22.7
110	Fiji	34.3	17.2	26.7	43.3	32.5	59.9
111	Nicaragua	34.2	7.9	22.5	41.6	26.0	26.2
112	Malaysia	34.0	9.2	22.9	42.0	25.2	80.1
113	Ghana	33.9	10.9	23.7	37.0	35.2	18.1
114	Sri Lanka	33.9	7.2	22.0	48.1	24.3	19.0
115	Peru	33.5	11.3	23.6	37.7	28.3	48.5
116	Georgia	33.1	12.7	24.0	32.3	36.2	43.0
117	Botswana	32.6	6.6	21.0	31.7	30.2	78.8
118	Colombia	31.7	10.9	22.4	32.8	27.0	39.9
119	Morocco	31.4	8.3	21.1	33.0	25.0	45.6
120	Mongolia	31.4	17.3	25.1	35.5	24.7	43.0
121	Ecuador	30.9	8.7	21.0	33.8	27.0	48.4
122	Azerbaijan	30.7	9.7	21.3	29.2	35.3	40.3
123	Belarus	30.5	10.3	21.5	30.8	33.3	63.9
124	China	30.5	10.4	21.5	34.7	21.0	94.0
125	Brazil	30.1	8.5	20.5	30.0	26.0	46.1
126	Philippines	30.1	7.8	20.2	35.4	19.7	33.9
127	Zambia	29.9	12.2	22.0	30.7	23.1	24.7
128	Kazakhstan	29.8	10.9	21.4	30.0	31.2	55.3
129	Kosovo (Disputed Territory)	29.1	7.6	19.5	30.8	24.2	60.5
130	Tunisia	29.1	5.3	18.5	34.9	17.9	35.8
131	Kenya	28.9	7.8	19.5	30.4	25.9	35.9
132	Paraguay	28.5	10.2	20.3	27.9	26.4	49.3
133	Iraq	28.4	7.3	19.0	28.1	25.5	58.0
134	Ukraine	28.2	8.2	19.2	28.8	25.4	50.0
135	Algeria	28.0	3.5	17.1	37.2	16.5	36.3
136	Tajikistan	27.9	9.7	19.8	35.2	20.0	39.5
137	Nigeria	27.7	22.8	25.5	31.4	21.0	8.3
138	Uzbekistan	27.3	12.2	20.6	30.1	23.0	47.8
139	Bolivia	27.3	8.6	19.0	28.4	22.2	43.6
140	Kyrgyzstan	27.3	12.0	20.4	27.6	23.6	40.6
141	Uganda	27.0	10.5	19.6	29.1	25.1	19.6
142	Tanzania	26.6	9.0	18.8	26.6	21.3	26.8
143	Vietnam	26.4	9.9	19.1	31.8	15.6	42.5
144	Indonesia	26.1	9.1	18.5	33.6	15.3	29.3
145	Syria	25.0	5.1	16.1	27.1	20.1	6.2
146	Rwanda	25.0	12.4	19.4	23.5	21.9	26.7
147	Iran	22.8	8.0	16.2	20.7	16.2	30.3
148	Bangladesh	22.8	2.6	13.8	26.8	17.5	34.6
149	Nepal	22.6	2.9	13.8	23.2	17.4	29.4
150	Madagascar	22.5	7.4	15.8	23.8	15.4	13.7
151	Egypt	21.6	4.0	13.8	22.2	20.1	21.8
152	Afghanistan	21.1	2.3	12.7	18.2	15.1	40.6
153	Pakistan	19.6	3.4	12.4	18.2	17.2	29.5
154	India	18.9	4.3	12.4	21.6	15.6	76.4
155	Libya	18.3	4.9	12.3	22.8	12.4	51.1
    EOF
  end
end
