class RecommendationsController < ApplicationController
  OMDB_API_KEY = ENV['OMDB_API_KEY']
  X_RAPIDAPI_KEY = ENV['X_RAPIDAPI_KEY']
  X_RAPIDAPI_HOST = ENV['X_RAPIDAPI_HOST']

  def search
    @genres = Query::GENRES
    @user = current_user
    @query = Query.new
  end

  def create
    @genres = Query::GENRES
    @query = Query.new(query_params)
    @query.medium = "movie and tv show" if @query.medium.nil?
    @query.user = current_user
    if @query.save
      redirect_to search_result_path(@query)
      create_openai_request(@query)
    else
      render :search
    end
  end

  def index
    @query = Query.find(params[:id])
    @query.medium = "movie and tv show" if @query.medium.nil?
    @mood = Query::MOOD[@query.happiness]
    @desired_mood = Query::MOOD[@query.desired_happiness]
    @display_prompt = create_display_prompt(@query, @mood, @desired_mood)
    @recommendations = Recommendation.where(query_id: @query.id)
    @watch_list_movies = WatchList.where(user: current_user)
    @watch_list = RecommendationWatchList.where(watch_list: @watch_list_movies)
  end

  def destroy
    @recommendation = Recommendation.find(params[:id])
    @recommendation.destroy
  end

  def show
    @recommendation = Recommendation.find(params[:id])
    get_streaming_availability(@recommendation.imdbID)

    @watch_list_movies = WatchList.where(user: current_user)
    @watch_list = RecommendationWatchList.where(watch_list: @watch_list_movies)
    @watch_list = @watch_list.map { |watch_list| watch_list.recommendation }
    @watch_list = @watch_list.filter { |recommendation| recommendation.movie_name == @recommendation.movie_name }
  end

  def add_recommendations
    @recommendation = Recommendation.find(params[:id])
    @watch_list = WatchList.find_by_id(user: current_user)
    @watch_list ||= WatchList.new(user: current_user)
    @recommendation.watch_lists << @watch_list

    if @recommendation.save
      @watch_list.save
    else
      flash[:alert] = "Something went wrong. Please try again."
    end
  end

  private

  def query_params
    params.require(:query).permit(
      :user_id, :time, :year_after, :year_before, :year_option, :happiness, :desired_happiness,
      :intensity, :novelty, :recent_movie1, :recent_movie2, :recent_movie3,
      :other, :audience, :medium
    ).tap do |query_params|
      query_params[:genre] = sanitize_params(params[:query][:genre])
      query_params[:streaming_platform] = sanitize_params(params[:query][:streaming_platform])
    end
  end

  def sanitize_params(params)
    params.reject { |_, value| value == "0" }.keys.join(", ")
  end

  def create_prompt(query, mood, desired_mood)
    prompt_parts = [
      "Show me a list of 10 real #{query.medium}s. Just display the titles in a hash format like: { \"#{query.medium}1\": \"#{query.medium} name\", ... }.",
      "Always list existing #{query.medium}s, NOT your preference.",
      "Remember to use double quotation marks to wrap the #{query.medium} name, but use single quotation marks within the #{query.medium} names.",
      "Do NOT include the #{query.medium} year or episode information.",
      "Here's some information about me:",
      ("I want to spend around #{query.time} minutes watching a #{query.medium}." if query.time.present? && query.time != 70 && query.time != 120),
      ("I enjoy #{query.genre} #{query.medium}s." if query.genre.present?),
      ("I'm currently feeling #{mood} and I'm in the mood for a #{query.medium} that makes me feel #{desired_mood}." if (query.desired_happiness.present? && query.happiness.present?) && ((query.desired_happiness < 4 || query.desired_happiness > 7) && (query.happiness < 4 || query.happiness > 7))),
      ("I'm currently feeling #{mood}" if (mood.present? && (query.happiness < 4 || query.happiness > 7))),
      ("I want to feel #{desired_mood}." if (desired_mood.present? && (query.desired_happiness < 4 || query.desired_happiness > 7))),
      ("I'm planning to watch this #{query.medium} with my partner." if query.audience == "Couple"),
      ("I'm planning to watch this #{query.medium} with my family." if query.audience == "Family"),
      ("I'm planning to watch this #{query.medium} by myself." if query.audience == "Just me"),
      ("I prefer a #{query.medium} where I don't have to concentrate too much." if query.intensity.present? && query.intensity < 4),
      ("I prefer a #{query.medium} that requires deep concentration." if query.intensity.present? && query.intensity > 7),
      ("The #{query.medium} should be originally released between #{query.year_after} and #{query.year_before}." if query.year_after != 1950 && query.year_before != 2023),
      ("I'm in the mood for something more experimental." if query.novelty.present? && query.novelty > 7),
      ("I'm in the mood for something more mainstream." if query.novelty.present? && query.novelty < 4),
      ("I really enjoyed watching #{query.recent_movie1}, #{query.recent_movie2}, and #{query.recent_movie3}. It would be great to find something similar now." if query.recent_movie1.present? || query.recent_movie2.present? || query.recent_movie3.present?),
      ("Consider my previous movie choices, but don't suggest them to me again." if query.recent_movie1.present? || query.recent_movie2.present? || query.recent_movie3.present?),
      ("Here's some additional information about myself and my day that can help you filter this #{query.medium}: #{query.other}." if query.other.present?),
      ("I have access to the following streaming platforms: #{query.streaming_platform}." if query.streaming_platform.present?),
      ("Please take into account all the information I provided and consider multiple aspects."),
      "Show me a list of 10 real #{query.medium}s. Just display the titles in a hash format like: { \"#{query.medium}1\": \"#{query.medium} name\", ... }.",
    ]
    prompt_parts.compact.join("\n")
    p prompt_parts.compact.join("\n")
  end

  def create_display_prompt(query, mood, desired_mood)
    prompt = ""
    prompt += "Hi! Looks like you're searching for a #{query.medium.downcase} recommendation.\n" if query.medium.present?
    prompt += "Since you're a bit short on time, I've got some shorter #{query.medium.downcase}s lined up for you.\n" if query.time.present? && query.time < 90 && query.medium == "Movie"
    prompt += "Since you have plenty of time on your hands, I've picked out some longer #{query.medium.downcase}s for you.\n" if query.time.present? && query.time > 90 && query.medium == "Movie"
    prompt += "I've tried my best to find #{query.medium.downcase}s that you can enjoy together with your partner.\n" if query.audience == "Couple"
    prompt += "I've tried my best to find #{query.medium.downcase}s that you can enjoy with your whole family.\n" if query.audience == "Family"
    prompt += "I've tried my best to find #{query.medium.downcase}s that you can enjoy all by yourself.\n" if query.audience == "Just me"
    prompt += "I get the sense that you're feeling #{mood.downcase} and want to feel #{desired_mood.downcase}. I hope I can help you with that.\n" if mood.present? && desired_mood.present?
    prompt += "I get the sense that you're feeling #{mood.downcase}.\n" if mood.present? && desired_mood.nil?
    prompt += "I get the sense that you want to feel #{desired_mood.downcase}. I hope I can help you with that.\n" if desired_mood.present? && mood.nil?
    prompt += "I've discovered some more experimental #{query.medium.downcase}s that might satisfy your craving for novelty.\n" if query.novelty.present? && query.novelty > 7
    prompt += "Some of the #{query.medium.downcase}s I choose for you share some similarities with #{query.recent_movie1}.\n" if query.recent_movie1.present?
    prompt += "Some of the #{query.medium.downcase}s I choose for you share some similarities with #{query.recent_movie1} and #{query.recent_movie2}.\n" if query.recent_movie1.present? && query.recent_movie2.present?
    prompt += "Enjoy your #{query.medium.downcase} and let me know how you liked my recommendations!\n"
    prompt
  end

  def create_recommendation(response, query)
    response.each do |_key, value|
      data = create_omdb_request(value)
      next if data.nil?

      create_recommendation_class(data, query)&.tap(&:save)
    end
  end

  def create_recommendation_class(data, query)
    Recommendation.new(
      user: current_user,
      movie_name: data['Title'],
      imdbID: data['imdbID'],
      genre: data['Genre'],
      year: data['Year'],
      rating: data['Rated'],
      image: data['Poster'],
      awards: data['Awards'],
      runtime: data['Runtime'],
      synopsis: data['Plot'],
      director: data['Director'],
      writer: data['Writer'],
      actors: data['Actors'],
      imdb_score: data['imdbRating'].present? ? data['imdbRating'] : nil,
      query_id: query
    )
  end

  def get_streaming_availability(imdbID)
    url = URI("https://streaming-availability.p.rapidapi.com/v2/get/basic?country=de&imdb_id=#{imdbID}&output_language=en")
    request = Net::HTTP::Get.new(url)
    request["X-RapidAPI-Key"] = X_RAPIDAPI_KEY
    request["X-RapidAPI-Host"] = X_RAPIDAPI_HOST
    response = Net::HTTP.start(url.hostname, url.port, use_ssl: true) do |http|
      http.request(request)
    end
    @data = JSON.parse(response.body)
    # @data = {
    #   "result" => {
    #   "type" => "movie",
    #   "title" => "The Dark Knight",
    #   "overview" => "Batman raises the stakes in his war on crime. With the help of Lt. Jim Gordon and District Attorney Harvey Dent, Batman sets out to dismantle the remaining criminal organizations that plague the streets. The partnership proves to be effective, but they soon find themselves prey to a reign of chaos unleashed by a rising criminal mastermind known to the terrified citizens of Gotham as the Joker.",
    #   "streamingInfo" => {
    #     "de" => {
    #       "hbo" => [
    #         {
    #           "type" => "subscription",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}",
    #         }
    #       ],
    #       "netflix" => [
    #         {
    #           "type" => "subscription",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}",
    #         }
    #       ],
    #       "disney" => [
    #         {
    #           "type" => "subscription",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}",
    #         }
    #       ],

    #       "wow" => [
    #         {
    #           "type" => "subscription",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}",
    #         }
    #       ],

    #       "hulu" => [
    #         {
    #           "type" => "buy",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}"
    #         }
    #       ],
    #       "wow" => [
    #         {
    #           "type" => "buy",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}"
    #         }
    #       ],
    #       "mubi" => [
    #         {
    #           "type" => "buy",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}"
    #         }
    #       ],

    #       "apple" => [
    #         {
    #           "type" => "rent",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}"
    #         }
    #       ],
    #       "prime" => [
    #         {
    #           "type" => "rent",
    #           "link" => "https://www.netflix.com/title/70079583/#{SecureRandom.hex(8)}"
    #         }
    #       ]
    #     }
    #   },
    #   "cast" => ["Christian Bale", "Heath Ledger", "Michael Caine", "Gary Oldman", "Aaron Eckhart", "Maggie Gyllenhaal", "Morgan Freeman"],
    #   "year" => 2008,
    #   "advisedMinimumAudienceAge" => 12,
    #   "imdbId" => "tt0468569",
    #   "imdbRating" => 90,
    #   "imdbVoteCount" => 2714996,
    #   "tmdbId" => 155,
    #   "tmdbRating" => 85,
    #   "originalTitle" => "The Dark Knight",
    #   "backdropPath" => "/dqK9Hag1054tghRQSqLSfrkvQnA.jpg",
    #   "backdropURLs" => {
    #     "1280" => "https://image.tmdb.org/t/p/w1280/dqK9Hag1054tghRQSqLSfrkvQnA.jpg",
    #     "300" => "https://image.tmdb.org/t/p/w300/dqK9Hag1054tghRQSqLSfrkvQnA.jpg",
    #     "780" => "https://image.tmdb.org/t/p/w780/dqK9Hag1054tghRQSqLSfrkvQnA.jpg",
    #     "original" => "https://image.tmdb.org/t/p/original/dqK9Hag1054tghRQSqLSfrkvQnA.jpg"
    #   },
    #   "genres" => [
    #     {"id" => 28, "name" => "Action"},
    #     {"id" => 80, "name" => "Crime"},
    #     {"id" => 18, "name" => "Drama"}
    #   ],
    #   "originalLanguage" => "en",
    #   "countries" => ["GB", "US"],
    #   "directors" => ["Christopher Nolan"],
    #   "runtime" => 152,
    #   "youtubeTrailerVideoId" => "kmJLuwP3MbY",
    #   "youtubeTrailerVideoLink" => "https://www.youtube.com/watch?v=kmJLuwP3MbY",
    #   "posterPath" => "/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
    #   "posterURLs" => {
    #     "154" => "https://image.tmdb.org/t/p/w154/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
    #     "185" => "https://image.tmdb.org/t/p/w185/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
    #     "342" => "https://image.tmdb.org/t/p/w342/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
    #     "500" => "https://image.tmdb.org/t/p/w500/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
    #     "780" => "https://image.tmdb.org/t/p/w780/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
    #     "92" => "https://image.tmdb.org/t/p/w92/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
    #     "original" => "https://image.tmdb.org/t/p/original/qJ2tW6WMUDux911r6m7haRef0WH.jpg"
    #   },
    #   "tagline" => "Welcome to a world without rules."}
    # }
  end

  def create_response_hash(response)
    if JSON.parse(response)
      return JSON.parse(response)
    else
      return { movie1: "Spirited Away", movie2: "Your Name", movie3: "Princess Mononoke", movie4: "Attack on Titan", movie6: "Serial Experiments Lain", movie5: "Death Note", movie7: "Perfect Blue", movie8: "Neon Genesis Evangelion", movie9: "FLCL", movie10: "Akira"}
    end
  end

  def create_omdb_request(movie_name)
    formatted_movie_name = movie_name.gsub(" ", '+')
    url = "http://www.omdbapi.com/?t=#{formatted_movie_name}&apikey=#{OMDB_API_KEY}"
    uri = URI(url)

    response = Net::HTTP.get(uri)
    JSON.parse(response)
  rescue StandardError => e
    Rails.logger.error("Error fetching movie details: #{e.message}")
    nil
  end

  def create_openai_request(query)
    mood = Query::MOOD[query.happiness]
    desired_mood = Query::MOOD[query.desired_happiness]
    # response = '{ "movie1": "Spirited Away", "movie2": "Your Name", "movie3": "Princess Mononoke", "movie4": "Attack on Titan", "movie6": "Serial Experiments Lain", "movie5": "Death Note", "movie7": "Perfect Blue", "movie8": "Neon Genesis Evangelion", "movie9": "FLCL", "movie10": "Akira"}'
    response = OpenaiService.new(create_prompt(query, mood, desired_mood)).call
    create_recommendation(create_response_hash(response), query.id)
  end
end
