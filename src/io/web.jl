using Temporal
using JSON
using Base.Dates
const YAHOO_URL = "https://query1.finance.yahoo.com/v7/finance/download"  # for querying yahoo's servers
const YAHOO_TMP = "https://ca.finance.yahoo.com/quote/^GSPC/history?p=^GSPC"  # for getting the cookies and crumbs
const QUANDL_URL = "https://www.quandl.com/api/v3/datasets"  # for querying quandl's servers
const GOOGLE_URL = "http://finance.google.com/finance/historical?"  # for querying google finance's servers

# ==============================================================================
# WEB INTERFACE ================================================================
# ==============================================================================

# function dateconv(s::String)
#     Dates.datetime2unix(Dates.DateTime(s))
# end

function isdate{T<:TimeType}(t::AbstractVector{T})::Bool
    h = Dates.hour.(t)
    m = Dates.minute.(t)
    s = Dates.second.(t)
    ms = Dates.millisecond.(t)
    return all(h.==h[1]) && all(m.==m[1]) && all(s.==s[1]) && all(ms.==ms[1])
end

function csvresp(resp::Requests.Response; sort::Char='d')
    @assert resp.status == 200 "Error in download request."
    rowdata = Vector{String}(split(readstring(resp), '\n'))
    header = Vector{String}(split(shift!(rowdata), ','))
    pop!(rowdata)
    if sort == 'd'
        reverse!(rowdata)
    elseif sort != 'a'
        error("Argument `sort` must be either 'a' (ascending) or 'd' (descending)")
    end
    N = length(rowdata)
    k = length(header)
    v = map(s -> Array{String}(split(s, ',')), rowdata)
    source_is_google = (header[1] == "\ufeffDate")
    if source_is_google
        header[1] = "Date"
        format = Dates.DateFormat("dd-uuu-yy")
        t = map(s -> Dates.DateTime(s[1], format), v)
        t .+= Dates.Year(2000)  # instead of year 0017, take year 2017
    else
        format = Dates.DateFormat("yyyy-mm-dd")
        t = map(s -> Dates.DateTime(s[1]), v)
    end
    isdate(t) ? t = Date.(t) : nothing
    data = zeros(Float64, (N,k-1))
    if length(header) == 2 && header[2] == "Stock Splits"
        # Logic to be applied for stock splits for Yahoo Finance downloads
        @inbounds for i in 1:N
            stock_split_string = split(v[i][2], '/')
            split_a = float(stock_split_string[1])
            split_b = float(stock_split_string[2])
            is_rev_split = split_a < split_b
            data[i,1] = split_b / split_a
        end
    else
        # Standard logic
        @inbounds for i in 1:N
            j = (v[i] .== "")
            v[i][find(j)] = "NaN"
            data[i,:] = float(v[i][2:k])
        end
    end
    return (data, t, header)
end

# ==============================================================================
# QUANDL INTERFACE =============================================================
# ==============================================================================
@doc doc"""
Set up Quandl user account authorization. Run once passing your Quandl API key, and it will be saved for future use.

`quandl_auth{T<:String}(key::T="")::String`


*Example*

```
julia> quandl_auth("Your_API_Key")
"Your_API_Key"

julia> quandl_auth()
"Your_API_Key"
```
""" ->
function quandl_auth{T<:String}(key::T="")::String
    authfile = "$(Pkg.dir())/quandl-auth"
    if key == ""
        if isfile(authfile)
            key = readstring(authfile)
        end
    else
        f = open(authfile, "w")
        write(f, key)
        close(f)
    end
    return key
end

@doc doc"""
Download time series data from Quandl as a TS object.
```
quandl(code::String;
       from::String="",
       thru::String="",
       freq::Char='d',
       calc::String="none",
       sort::Char='a',
       rows::Int=0,
       auth::String=quandl_auth())::TS
```


# Example

```
julia> quandl("CHRIS/CME_CL1", from="2010-01-01", thru=string(Dates.today()), freq='a')
8x8 Temporal.TS{Float64,Date}: 2010-12-31 to 2017-12-31
Index       Open   High    Low    Last   Change  Settle  Volume    PreviousDayOpenInterest
2010-12-31  89.67  92.06   89.05  91.38  NaN     91.38   171010.0  311738.0
2011-12-31  99.78  100.16  98.61  98.83  NaN     98.83   151380.0  233377.0
2012-12-31  90.41  91.99   90.0   91.82  NaN     91.82   107767.0  277570.0
2013-12-31  99.25  99.39   98.15  98.42  NaN     98.42   100104.0  259878.0
2014-12-31  53.87  54.02   52.44  53.27  0.85    53.27   247510.0  309473.0
2015-12-31  36.81  37.79   36.22  37.07  0.44    37.04   279553.0  436421.0
2016-12-31  53.87  54.09   53.41  53.89  0.05    53.72   266762.0  457983.0
2017-12-31  48.47  49.63   48.38  49.6   1.14    49.51   540748.0  606895.0
```
""" ->
function quandl(code::String;
                from::String="",
                thru::String="",
                freq::Char='d',
                calc::String="none",
                sort::Char='a',
                rows::Int=0,
                auth::String=quandl_auth())::TS
    # Check arguments =========================================================
    @assert from=="" || (from[5]=='-' && from[8]=='-') "Argument `from` has invlalid format."
    @assert thru=="" || (thru[5]=='-' && thru[8]=='-') "Argument `thru` has invlalid format."
    @assert freq in ['d', 'w', 'm', 'q', 'a'] "Invalid `freq` argument (must be in ['d', 'w', 'm', 'q', 'a'])."
    @assert calc in ["none","diff","rdiff","cumul","normalize"] "Invalid `calc` argument."
    @assert sort  == 'a' || sort == 'd' "Argument `sort` must be either \'a\' or \'d\'."
    if rows != 0 && (from != "" || thru != "")
        error("Cannot specify `rows` and date range (`from` or `thru`).")
    end
    # Format URL ===============================================================
    sort_arg = (sort=='a' ? "asc" : "des")
    freq_arg = (freq=='d'?"daily":(freq=='w'?"weekly":(freq=='m'?"monthly":(freq=='q'?"quarterly":(freq=='a'?"annual":"")))))
    if rows == 0
        fromstr = from == "" ? "" : "&start_date=$from"
        thrustr = thru == "" ? "" : "&end_date=$thru"
        url = "$QUANDL_URL/$code.csv?$(fromstr)$(thrustr)&order=$sort_arg&collapse=$freq_arg&transform=$calc&api_key=$auth"
    else
        url = "$QUANDL_URL/$code.csv?&rows=$rows&order=$sort_arg&collapse=$freq_arg&transform=$calc&api_key=$auth"
    end
    indata = csvresp(get(url), sort=sort)
    return TS(indata[1], indata[2], indata[3][2:end])
end

@doc doc"""
Download Quandl metadata for a database and dataset into a Julia Dict object.

`quandl_meta(database::String, dataset::String)`
""" ->
function quandl_meta(database::String, dataset::String)::Dict{String,Any}
    resp = get("$QUANDL_URL/$database/$dataset/metadata.json")
    @assert resp.status == 200 "Error downloading metadata from Quandl."
    return JSON.parse(readstring(resp))["dataset"]
end

@doc doc"""
Search Quandl for data in a given database, `db`, or matching a given query, `qry`.

`quandl_search(;db::String="", qry::String="", perpage::Int=1, pagenum::Int=1)`
""" ->
function quandl_search(;db::String="", qry::String="", perpage::Int=1, pagenum::Int=1)
    @assert db!="" || qry!="" "Must enter a database or a search query."
    dbstr = db   == "" ? "" : "database_code=$db&"
    qrystr = qry  == "" ? "" : "query=$(replace(qry, ' ', '+'))&"
    resp = get("$QUANDL_URL.json?$(dbstr)$(qrystr)per_page=$perpage&page=$pagenum")
    @assert resp.status == 200 "Error retrieving search results from Quandl"
    return JSON.parse(readstring(resp))
end

# ==============================================================================
# YAHOO INTERFACE ==============================================================
# ==============================================================================
function yahoo_get_crumb()::Tuple{SubString{String}, Dict{String, Requests.HttpCommon.Cookie}}
    response = Requests.get(YAHOO_TMP)
    m = match(r"\"user\":{\"crumb\":\"(.*?)\"", readstring(response))
    return (m[1], Requests.cookies(response))
end

@doc doc"""
Download stock price data from Yahoo! Finance into a TS object.

`yahoo(symb::String; from::String="1900-01-01", thru::String=string(Dates.today()), freq::String="d", event::String="history", crumb_tuple::Tuple{SubString{String}, Dict{String, Requests.HttpCommon.Cookie}}=yahoo_get_crumb())::TS`

# Arguments
- `symb` ticker symbol of the stock
- `from` starting date of the historical data request (string formatted as yyyy-mm-dd)
- `thru` ending date of the historical data request (string formatted as yyyy-mm-dd)
- `freq` frequency interval of the requested dowload (valid options are \"d\" for daily, \"wk\" for weekly, and \"mo\" for monthly)
- `event` type of data download to request (valid options are \"history\" for standard historical price data, \"div\" for dividend payments, and \"split\" for stock splits)
- `crumb_tuple` workaround to provide crumbs/cookies for the new Yahoo Finance portal (which requires such data to fulfill the requests)

# Example

```
julia> yahoo("AAPL", from="2010-06-09", thru=string(Dates.today()), freq="wk")
356x6 Temporal.TS{Float64,Date}: 2010-06-09 to 2017-03-27
Index       Open    High    Low     Close   Volume      AdjClose
2010-06-09  251.47  253.86  242.2   253.51  1.813954e8  32.8446
2010-06-14  255.96  275.0   254.01  274.07  1.814594e8  35.5084
2010-06-21  277.69  279.01  265.81  266.7   1.763214e8  34.5535
2010-06-28  266.93  269.75  243.2   246.94  2.087241e8  31.9934
2010-07-06  251.0   262.9   246.16  259.62  1.525786e8  33.6362
⋮
2017-02-27  137.14  140.28  136.28  139.78  2.54267e7   139.78
2017-03-06  139.37  139.98  137.05  139.14  1.97315e7   139.14
2017-03-13  138.85  141.02  138.82  139.99  2.41057e7   139.99
2017-03-20  140.4   142.8   139.73  140.64  2.54857e7   140.64
2017-03-27  139.39  144.49  138.62  144.12  2.86449e7   144.12
```
""" ->
function yahoo(symb::String;
               from::String="1900-01-01",
               thru::String=string(Dates.today()),
               freq::String="d",
               event::String="history",
               crumb_tuple::Tuple{SubString{String}, Dict{String, Requests.HttpCommon.Cookie}}=yahoo_get_crumb())::TS
    @assert freq in ["d","wk","mo"] "Argument `freq` must be either \"d\" (daily), \"wk\" (weekly), or \"mo\" (monthly)."
    @assert event in ["history","div","split"] "Argument `event` must be either \"history\", \"div\", or \"split\"."
    @assert from[5] == '-' && from[8] == '-' "Argument `from` has invalid date format."
    @assert thru[5] == '-' && thru[8] == '-' "Argument `thru` has invalid date format."
    period1 = Int(floor(Dates.datetime2unix(Dates.DateTime(from))))
    period2 = Int(floor(Dates.datetime2unix(Dates.DateTime(thru))))
    urlstr = "$(YAHOO_URL)/$(symb)?period1=$(period1)&period2=$(period2)&interval=1$(freq)&events=$(event)&crumb=$(crumb_tuple[1])"
    response = Requests.get(urlstr, cookies=crumb_tuple[2])
    indata = Temporal.csvresp(response)
    return TS(indata[1], indata[2], indata[3][2:end])
end

function yahoo(syms::Vector{String};
               from::String="1900-01-01",
               thru::String=string(Dates.today()),
               freq::String="d",
               event::String="history",
               crumb_tuple::Tuple{SubString{String}, Dict{String, Requests.HttpCommon.Cookie}}=yahoo_get_crumb())::Dict{String,TS}
    out = Dict()
    for s = syms
        out[s] = yahoo(s, from=from, thru=thru, freq=freq, event=event, crumb_tuple=crumb_tuple)
    end
    return out
end

# ==============================================================================
# QUANDL INTERFACE =============================================================
# ==============================================================================
@doc doc"""
Download stock price data from Google Finance into a TS object.

`google(symb::String; from::String="2000-01-01", thru::String=string(Dates.today()))::TS`

# Arguments
- `symb` ticker symbol of the stock
- `from` starting date of the historical data request (string formatted as yyyy-mm-dd)
- `thru` ending date of the historical data request (string formatted as yyyy-mm-dd)

# Example

```
julia> google("IBM", from="2010-06-09", thru=string(Dates.today()))
1756x5 Temporal.TS{Float64,Date}: 2010-06-09 to 2017-05-30
Index       Open    High    Low     Close   Volume
2010-06-09  124.83  125.84  123.58  123.9   7.800309e6
2010-06-10  125.99  128.22  125.8   127.68  7.47961e6
2010-06-11  126.73  128.8   126.44  128.45  5.827093e6
2010-06-14  128.5   129.97  128.49  128.5   6.753113e6
2010-06-15  128.93  129.95  128.37  129.79  6.652612e6
⋮
2017-05-23  152.57  153.68  151.92  152.03  2.564503e6
2017-05-24  152.21  152.76  151.23  152.51  3.732399e6
2017-05-25  153.25  153.73  152.95  153.2   2.582815e6
2017-05-26  152.85  153.0   152.06  152.49  2.443507e6
2017-05-30  151.95  152.67  151.59  151.73  3.666032e6
```
""" ->
function google(symb::String;
                from::String="2000-01-01",
                thru::String=string(Dates.today()))::TS
    from_date = parse(Date, from, Dates.DateFormat("yyyy-mm-dd"))
    thru_date = parse(Date, thru, Dates.DateFormat("yyyy-mm-dd"))
    url = string("$(GOOGLE_URL)q=$(symb)",
                 "&startdate=$(Dates.monthabbr(Dates.month(from_date)))",
                 "+$(@sprintf("%.2d",Dates.dayofmonth(from_date)))",
                 "+$(Dates.year(from_date))",
                 "&enddate=$(Dates.monthabbr(thru_date))",
                 "+$(@sprintf("%.2d",Dates.dayofmonth(thru_date)))",
                 "+$(Dates.year(thru_date))&output=csv")
    response = Requests.get(url)
    indata = Temporal.csvresp(response)
    return TS(indata[1], indata[2], indata[3][2:end])
end