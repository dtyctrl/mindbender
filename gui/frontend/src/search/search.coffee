angular.module "mindbenderApp.search", [
    'elasticsearch'
    'json-tree'
    'ngSanitize'
]

# elasticsearch client as an Angular service
.service "elasticsearch", (esFactory) ->
    BASEURL = location.href.substring(0, location.href.length - location.hash.length)
    elasticsearch = esFactory {
        host: "#{BASEURL}api/elasticsearch"
    }
    # do a ping
    elasticsearch.ping {
        requestTimeout: 30000
    }, (err) ->
        console.trace "elasticsearch cluster is down", err if err
    # return the instance
    elasticsearch

.config ($routeProvider) ->
    $routeProvider.when "/search/:index*?",
        brand: "DeepDive", brandIcon: "search"
        title: 'Search {{
                q ? "for [" + q + "] " : "everything "}}{{
                t ? "in " + t + " " : ""}}{{
                index ? "(" + index + ") " : ""
            }}- DeepDive'
        templateUrl: "search/search.html"
        controller: "SearchCtrl"
        reloadOnSearch: no
    $routeProvider.when "/search",
        redirectTo: "/search/"

.controller "SearchCtrl", ($scope, $location, $routeParams, elasticsearch, $http, $interpolate, $modal) ->
    RENDER_SOURCE_JSON = $interpolate "{{_source | json | limitTo:500}}"
    class Navigator
        constructor: (@elasticsearchIndexName = "_all", @$scope) ->
            @query = @results = null
            @paramsDefault =
                q: null # query string
                t: null # type to search
                n: 10   # number of items in a page
                p: 1    # page number (starts from 1)
            @params = _.extend {}, @paramsDefault
            do @importParams

            $http.get "/api/search/schema.json"
                .success (data) =>
                    @schema = data
                    @doSearch yes
                .error (err) ->
                    console.trace err

            # find out what types are in the index
            @types = null
            elasticsearch.indices.get
                index: @elasticsearchIndexName
            .then (data) =>
                @types = _.union (_.keys mappings for idx,{mappings} of data)...
            , (err) =>
                @error = err
                console.trace err.message

            # watch page number changes
            @$scope.$watch (=> @params.p), => @doSearch yes
            @$scope.$on "$routeUpdate", =>
                @doSearch yes if do @importParams

        doSearch: (isContinuing = no) =>
            @params.p = 1 unless isContinuing
            fieldsSearchable = @getSearchableFields @params.t
            aggs = {}
            for navigable in fieldsSearchable # TODO fieldsNavigable for type,{navigable} of @schema
                aggs[navigable] =
                    # TODO when text
                    #significant_terms: navigable
                    # TODO when numeric
                    # TODO when other type
                    significant_terms:
                        field: navigable
            @error = null
            @queryRunning =
                index: @elasticsearchIndexName
                type: @params.t
                body:
                    # elasticsearch Query DSL (See: https://www.elastic.co/guide/en/elasticsearch/client/javascript-api/current/quick-start.html#_elasticsearch_query_dsl)
                    size: @params.n
                    from: (@params.p - 1) * @params.n
                    query: if @params.q
                        query_string:
                            default_operator: "AND"
                            query: @params.q
                    # TODO support filters
                    # TODO support aggs
                    aggs: aggs
                    highlight:
                        tags_schema: "styled"
                        fields: _.object ([f,{}] for f in fieldsSearchable)
            postProcessSearchResults = =>
                @query = @queryRunning
                @queryRunning = null
                @fieldsSearchable = fieldsSearchable
                do @reflectParams
            elasticsearch.search @queryRunning
            .then (data) =>
                @error = null
                @results = data
                do postProcessSearchResults
            , (err) =>
                @error = err
                console.trace err.message
                @results = null
                do postProcessSearchResults

        doNavigate: (field, value) =>
            qExtra =
                if false # TODO if field is non-text type
                    "#{field}:#{value}"
                else
                    value
            # TODO check if qExtra is already there
            @params.q += " #{qExtra}"
            @doSearch no

        getSearchableFields: (type = @params.t) =>
            # get all searchable fields based on @params.t
            if type?
                @schema?[type]?.columnsForSearch ? []
            else
                _.union (columnsForSearch for t,{columnsForSearch} of @schema)...

        importParams: =>
            search = $location.search()
            changed = no
            for k,v of @params when (search[k] ? @paramsDefault[k]) isnt v
                @params[k] = search[k] ? @paramsDefault[k]
                changed = yes
            changed

        reflectParams: =>
            # reflect search parameters to the location on the URL
            search = $location.search()
            $location.search k, v for k, v of @params when search.k isnt v

    $scope.search = new Navigator $routeParams.index, $scope

    $scope.openModal = (options) ->
        $modal.open _.extend {
            scope: $scope
        }, options
