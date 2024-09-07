//
//  AnimeDetailsViewController.swift
//  Ryu
//
//  Created by Francesco on 22/06/24.
//

import UIKit
import AVKit
import WebKit
import SwiftSoup
import GoogleCast
import Kingfisher
import SafariServices

class AnimeDetailViewController: UITableViewController, GCKRemoteMediaClientListener, AVPlayerViewControllerDelegate {
    var animeTitle: String?
    var imageUrl: String?
    var href: String?
    
    var episodes: [Episode] = []
    var synopsis: String = ""
    var aliases: String = ""
    var airdate: String = ""
    var stars: String = ""
    
    var player: AVPlayer?
    var playerViewController: AVPlayerViewController?
    
    var currentEpisodeIndex: Int = 0
    var timeObserverToken: Any?
    
    var isFavorite: Bool = false
    var isSynopsisExpanded = false
    var isReverseSorted = false
    
    var availableQualities: [String] = []
    var qualityOptions: [(name: String, fileName: String)] = []
    var hasSentUpdate = false
    
    func configure(title: String, imageUrl: String, href: String) {
        self.animeTitle = title
        self.imageUrl = imageUrl
        self.href = href
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateUI()
        setupNotifications()
        checkFavoriteStatus()
        setupAudioSession()
        setupCastButton()
        
        isReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        setupUserDefaultsObserver()
        sortEpisodes()
        
        navigationController?.navigationBar.prefersLargeTitles = false
        
        for (index, episode) in episodes.enumerated() {
            if let cell = tableView.cellForRow(at: IndexPath(row: index, section: 2)) as? EpisodeCell {
                cell.loadSavedProgress(for: episode.href)
            }
        }
        
        if let firstEpisodeHref = episodes.first?.href {
            currentEpisodeIndex = episodes.firstIndex(where: { $0.href == firstEpisodeHref }) ?? 0
        }
    }
    
    private func setupCastButton() {
        let castButton = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: castButton)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        
        if let castSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
           let remoteMediaClient = castSession.remoteMediaClient {
            remoteMediaClient.remove(self)
        }
    }
    
    private func toggleFavorite() {
        isFavorite.toggle()
        if let anime = createFavoriteAnime() {
            if isFavorite {
                FavoritesManager.shared.addFavorite(anime)
            } else {
                FavoritesManager.shared.removeFavorite(anime)
            }
        }
        tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
    }
    
    private func createFavoriteAnime() -> FavoriteItem? {
        guard let title = animeTitle,
              let imageURL = URL(string: imageUrl ?? ""),
              let contentURL = URL(string: href ?? "") else {
                  return nil
              }
        let selectedMediaSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? "AnimeWorld"
        
        return FavoriteItem(title: title, imageURL: imageURL, contentURL: contentURL, source: selectedMediaSource)
    }
    
    private func checkFavoriteStatus() {
        if let anime = createFavoriteAnime() {
            isFavorite = FavoritesManager.shared.isFavorite(anime)
        }
    }
    
    private func setupUI() {
        view.backgroundColor = .secondarySystemBackground
        tableView.register(AnimeHeaderCell.self, forCellReuseIdentifier: "AnimeHeaderCell")
        tableView.register(SynopsisCell.self, forCellReuseIdentifier: "SynopsisCell")
        tableView.register(EpisodeCell.self, forCellReuseIdentifier: "EpisodeCell")
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                  return
              }
        
        switch type {
        case .began:
            player?.pause()
        case .ended:
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                player?.play()
            } catch {
                print("Failed to reactivate AVAudioSession: \(error)")
            }
        default:
            break
        }
    }
    
    private func updateUI() {
        if let href = href {
            AnimeDetailService.fetchAnimeDetails(from: href) { [weak self] (result) in
                switch result {
                case .success(let details):
                    self?.aliases = details.aliases
                    self?.synopsis = details.synopsis
                    self?.airdate = details.airdate
                    self?.stars = details.stars
                    self?.episodes = details.episodes
                    self?.sortEpisodes()
                    DispatchQueue.main.async {
                        self?.tableView.reloadData()
                    }
                case .failure(let error):
                    self?.showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }
    
    private func sortEpisodes() {
        episodes = isReverseSorted ? episodes.sorted(by: { $0.episodeNumber > $1.episodeNumber }) : episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber })
    }
    
    private func setupUserDefaultsObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    @objc private func userDefaultsChanged() {
        let newIsReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        if newIsReverseSorted != isReverseSorted {
            isReverseSorted = newIsReverseSorted
            sortEpisodes()
            tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
        }
    }
    
    func showAlert(title: String, message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let topController = windowScene.windows.first?.rootViewController?.presentedViewController ?? windowScene.windows.first?.rootViewController {
            topController.present(alertController, animated: true, completion: nil)
        }
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0, 1: return 1
        case 2: return episodes.count
        default: return 0
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            let cell = tableView.dequeueReusableCell(withIdentifier: "AnimeHeaderCell", for: indexPath) as! AnimeHeaderCell
            cell.configure(title: animeTitle, imageUrl: imageUrl, aliases: aliases, isFavorite: isFavorite, airdate: airdate, stars: stars, href: href)
            cell.favoriteButtonTapped = { [weak self] in
                self?.toggleFavorite()
            }
            cell.showOptionsMenu = { [weak self] in
                self?.showOptionsMenu()
            }
            return cell
        case 1:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SynopsisCell", for: indexPath) as! SynopsisCell
            cell.configure(synopsis: synopsis, isExpanded: isSynopsisExpanded)
            cell.delegate = self
            return cell
        case 2:
            let cell = tableView.dequeueReusableCell(withIdentifier: "EpisodeCell", for: indexPath) as! EpisodeCell
            let episode = episodes[indexPath.row]
            cell.configure(episode: episode, delegate: self)
            cell.loadSavedProgress(for: episode.href)
            return cell
        default:
            return UITableViewCell()
        }
    }
    
    private func showOptionsMenu() {
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        let advancedSettingsAction = UIAlertAction(title: "Advanced Settings", style: .default) { [weak self] _ in
            self?.showAdvancedSettingsMenu()
        }
        advancedSettingsAction.setValue(UIImage(systemName: "gear"), forKey: "image")
        alertController.addAction(advancedSettingsAction)
        
        let fetchIDAction = UIAlertAction(title: "AniList Info", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let cleanedTitle = self.cleanTitle(self.animeTitle ?? "Title")
            self.fetchAndNavigateToAnime(title: cleanedTitle)
        }
        fetchIDAction.setValue(UIImage(systemName: "info.circle"), forKey: "image")
        alertController.addAction(fetchIDAction)
        
        let openOnWebAction = UIAlertAction(title: "Open in Web", style: .default) { [weak self] _ in
            self?.openAnimeOnWeb()
        }
        openOnWebAction.setValue(UIImage(systemName: "safari"), forKey: "image")
        alertController.addAction(openOnWebAction)
        
        let refreshAction = UIAlertAction(title: "Refresh", style: .default) { [weak self] _ in
            self?.refreshAnimeDetails()
        }
        refreshAction.setValue(UIImage(systemName: "arrow.clockwise"), forKey: "image")
        alertController.addAction(refreshAction)
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(cancelAction)
        
        if let popoverController = alertController.popoverPresentationController {
            popoverController.sourceView = view
            popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = []
        }
        
        present(alertController, animated: true, completion: nil)
    }
    
    private func showAdvancedSettingsMenu() {
        let alertController = UIAlertController(title: "Advanced Settings", message: nil, preferredStyle: .actionSheet)
        
        let customAniListIDAction = UIAlertAction(title: "Custom AniList ID", style: .default) { [weak self] _ in
            self?.customAniListID()
        }
        customAniListIDAction.setValue(UIImage(systemName: "pencil"), forKey: "image")
        alertController.addAction(customAniListIDAction)
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(cancelAction)
        
        if let popoverController = alertController.popoverPresentationController {
            popoverController.sourceView = view
            popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = []
        }
        
        present(alertController, animated: true, completion: nil)
    }
    
    private func customAniListID() {
        let alert = UIAlertController(title: "Custom AniList ID", message: "Enter a custom AniList ID for this anime:", preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "AniList ID"
            if let animeTitle = self.animeTitle {
                let customID = UserDefaults.standard.string(forKey: "customAniListID_\(animeTitle)")
                textField.text = customID
            }
        }
        
        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            if let animeTitle = self?.animeTitle, let textField = alert.textFields?.first, let customID = textField.text, !customID.isEmpty {
                UserDefaults.standard.setValue(customID, forKey: "customAniListID_\(animeTitle)")
            } else {
                self?.showAlert(title: "Error", message: "AniList ID cannot be empty.")
            }
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .destructive, handler: nil)
        
        let revertAction = UIAlertAction(title: "Revert", style: .default) { [weak self] _ in
            if let animeTitle = self?.animeTitle {
                UserDefaults.standard.removeObject(forKey: "customAniListID_\(animeTitle)")
                self?.showAlert(title: "Reverted", message: "The custom AniList ID has been cleared.")
            }
        }

        alert.addAction(saveAction)
        alert.addAction(revertAction)
        alert.addAction(cancelAction)
        
        present(alert, animated: true, completion: nil)
    }
    
    func cleanTitle(_ title: String) -> String {
        let unwantedStrings = ["(ITA)", "(Dub)", "(Dub ID)", "(Dublado)"]
        var cleanedTitle = title
        
        for unwanted in unwantedStrings {
            cleanedTitle = cleanedTitle.replacingOccurrences(of: unwanted, with: "")
        }
        
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "\"", with: "")
        return cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func fetchAndNavigateToAnime(title: String) {
        if let customID = UserDefaults.standard.string(forKey: "customAniListID_\(animeTitle ?? "")") {
            navigateToAnimeDetail(for: Int(customID) ?? 0)
        } else {
            AnimeService.fetchAnimeID(byTitle: title) { [weak self] result in
                switch result {
                case .success(let id):
                    self?.navigateToAnimeDetail(for: id)
                case .failure(let error):
                    print("Error fetching anime ID: \(error.localizedDescription)")
                    self?.showAlert(title: "Error", message: "Unable to find the anime ID from AniList")
                }
            }
        }
    }
    
    private func navigateToAnimeDetail(for animeID: Int) {
        let storyboard = UIStoryboard(name: "AnilistAnimeInformation", bundle: nil)
        if let animeDetailVC = storyboard.instantiateViewController(withIdentifier: "AnimeInformation") as? AnimeInformation {
            animeDetailVC.animeID = animeID
            navigationController?.pushViewController(animeDetailVC, animated: true)
        }
    }
    
    private func openAnimeOnWeb() {
        guard let path = href else {
            print("Invalid URL string: \(href ?? "nil")")
            showAlert(withTitle: "Error", message: "The URL is invalid.")
            return
        }
        
        let selectedSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
        let baseUrl: String
        
        switch selectedSource {
        case "AnimeWorld":
            baseUrl = "https://animeworld.so"
        case "GoGoAnime":
            baseUrl = "https://anitaku.pe"
        case "AnimeHeaven":
            baseUrl = "https://animeheaven.me/"
        case "HiAnime":
            baseUrl = "https://hianime.to/watch/"
        default:
            baseUrl = ""
        }
        
        let fullUrlString = baseUrl + path
        
        guard let url = URL(string: fullUrlString) else {
            print("Invalid URL string: \(fullUrlString)")
            showAlert(withTitle: "Error", message: "The URL is invalid.")
            return
        }
        
        let safariViewController = SFSafariViewController(url: url)
        present(safariViewController, animated: true, completion: nil)
    }
    
    private func refreshAnimeDetails() {
        let loadingIndicator = UIActivityIndicatorView(style: .medium)
        loadingIndicator.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: loadingIndicator)
        
        if let href = href {
            AnimeDetailService.fetchAnimeDetails(from: href) { [weak self] result in
                DispatchQueue.main.async {
                    self?.navigationItem.rightBarButtonItem = nil
                    
                    switch result {
                    case .success(let details):
                        self?.updateAnimeDetails(with: details)
                        self?.setupCastButton()
                    case .failure(let error):
                        self?.showAlert(withTitle: "Refresh Failed", message: error.localizedDescription)
                        self?.setupCastButton()
                    }
                }
            }
        } else {
            showAlert(withTitle: "Error", message: "Unable to refresh. No valid URL found.")
        }
    }
    
    private func updateAnimeDetails(with details: AnimeDetail) {
        aliases = details.aliases
        synopsis = details.synopsis
        airdate = details.airdate
        stars = details.stars
        episodes = details.episodes
        
        tableView.reloadData()
    }
    
    func showAlert(withTitle title: String, message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let okAction = UIAlertAction(title: "OK", style: .default, handler: nil)
        alertController.addAction(okAction)
        present(alertController, animated: true, completion: nil)
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 2 {
            let episode = episodes[indexPath.row]
            if let cell = tableView.cellForRow(at: indexPath) as? EpisodeCell {
                episodeSelected(episode: episode, cell: cell)
            }
        }
    }
    
    func episodeSelected(episode: Episode, cell: EpisodeCell) {
        let selectedSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? "AnimeWorld"
        currentEpisodeIndex = episodes.firstIndex(where: { $0.href == episode.href }) ?? 0
        
        var baseURL: String
        var fullURL: String
        var episodeId: String
        var episodeTimeURL: String
        
        switch selectedSource {
        case "AnimeWorld":
            baseURL = "https://www.animeworld.so/api/episode/serverPlayerAnimeWorld?id="
            episodeId = episode.href.components(separatedBy: "/").last ?? episode.href
            fullURL = baseURL + episodeId
            episodeTimeURL = episode.href
            checkUserDefault(url: fullURL, cell: cell, fullURL: episodeTimeURL)
            return
        case "AnimeHeaven":
            baseURL = "https://animeheaven.me/"
            episodeId = episode.href
            fullURL = baseURL + episodeId
            episodeTimeURL = episode.href
            checkUserDefault(url: fullURL, cell: cell, fullURL: episodeTimeURL)
            return
        case "GoGoAnime":
            baseURL = "https://anitaku.pe/"
            episodeId = episode.href.components(separatedBy: "/").last ?? episode.href
            fullURL = baseURL + episodeId
            episodeTimeURL = episode.href
            checkUserDefault(url: fullURL, cell: cell, fullURL: episodeTimeURL)
            return
        default:
            baseURL = ""
            episodeId = episode.href
            fullURL = baseURL + episodeId
            checkUserDefault(url: fullURL, cell: cell, fullURL: fullURL)
            return
        }
    }
    
    private func checkUserDefault(url: String, cell: EpisodeCell, fullURL: String) {
        if UserDefaults.standard.bool(forKey: "isToDownload") {
            playEpisode(url: url, cell: cell, fullURL: fullURL)
        } else if UserDefaults.standard.bool(forKey: "browserPlayer") {
            openInWeb(fullURL: url)
        } else {
            playEpisode(url: url, cell: cell, fullURL: fullURL)
        }
    }
    
    @objc private func openInWeb(fullURL: String) {
        let selectedMediaSource = UserDefaults.standard.string(forKey: "selectedMediaSource")
        
        if selectedMediaSource == "HiAnime" {
            if let extractedID = extractEpisodeId(from: fullURL) {
                let hiAnimeURL = "https://hianime.to/watch/\(extractedID)"
                print(hiAnimeURL)
                openSafariViewController(with: hiAnimeURL)
            } else {
                showAlert(title: "Error", message: "Unable to extract episode ID")
            }
        } else {
            openSafariViewController(with: fullURL)
        }
    }
    
    private func openSafariViewController(with urlString: String) {
        guard let url = URL(string: urlString) else {
            showAlert(title: "Error", message: "Unable to open the webpage")
            return
        }
        let safariViewController = SFSafariViewController(url: url)
        present(safariViewController, animated: true, completion: nil)
    }
    
    @objc func startStreamingButtonTapped(withURL url: String, captionURL: String, playerType: String, cell: EpisodeCell, fullURL: String) {
        deleteWebKitFolder()
        presentStreamingView(withURL: url, captionURL: captionURL, playerType: playerType, cell: cell, fullURL: fullURL)
    }
    
    func presentStreamingView(withURL url: String, captionURL: String, playerType: String, cell: EpisodeCell, fullURL: String) {
        DispatchQueue.main.async {
            var streamingVC: UIViewController
            switch playerType {
            case VideoPlayerType.standard:
                streamingVC = ExternalVideoPlayer(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
            case VideoPlayerType.player3rb:
                streamingVC = ExternalVideoPlayer3rb(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
            case VideoPlayerType.playerKura:
                streamingVC = ExternalVideoPlayerKura(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
            case VideoPlayerType.playerJK:
                streamingVC = ExternalVideoPlayerJK(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
            case VideoPlayerType.playerWeb:
                streamingVC = HiAnimeWebPlayer(streamURL: url, captionURL: captionURL, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
            default:
                return
            }
            streamingVC.modalPresentationStyle = .fullScreen
            self.present(streamingVC, animated: true, completion: nil)
        }
    }
    
    func deleteWebKitFolder() {
        if let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let webKitFolderPath = libraryPath.appendingPathComponent("WebKit")
            do {
                if FileManager.default.fileExists(atPath: webKitFolderPath.path) {
                    try FileManager.default.removeItem(at: webKitFolderPath)
                    print("Successfully deleted the WebKit folder.")
                } else {
                    print("The WebKit folder does not exist.")
                }
            } catch {
                print("Error deleting the WebKit folder: \(error.localizedDescription)")
            }
        } else {
            print("Could not find the Library directory.")
        }
    }
    
    func playEpisode(url: String, cell: EpisodeCell, fullURL: String) {
        hasSentUpdate = false
        
        guard let videoURL = URL(string: url) else {
            print("Invalid URL: \(url)")
            return
        }
        
        let selectedMediaSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
        
        if selectedMediaSource == "HiAnime" {
            handleHiAnimeSource(url: url, cell: cell, fullURL: fullURL)
        } else if url.contains(".mp4") || url.contains(".m3u8") || url.contains("animeheaven.me/video.mp4") {
            DispatchQueue.main.async {
                self.playVideo(sourceURL: videoURL, cell: cell, fullURL: fullURL)
            }
        } else {
            handleSources(url: url, cell: cell, fullURL: fullURL)
        }
    }
    
    private func handleHiAnimeSource(url: String, cell: EpisodeCell, fullURL: String) {
        guard let episodeId = extractEpisodeId(from: url) else {
            print("Could not extract episodeId from URL")
            DispatchQueue.main.async {
                self.showAlert(title: "Error", message: "Could not extract episodeId from URL")
            }
            return
        }
        
        fetchEpisodeOptions(episodeId: episodeId) { [weak self] options in
            guard let self = self else { return }
            
            if options.isEmpty {
                print("No options available for this episode")
                DispatchQueue.main.async {
                    self.showAlert(title: "Error", message: "No options available for this episode")
                }
                return
            }
            
            let preferredAudio = UserDefaults.standard.string(forKey: "audioHiPrefe") ?? ""
            let preferredServer = UserDefaults.standard.string(forKey: "serverHiPrefe") ?? ""
            
            self.selectAudioCategory(options: options, preferredAudio: preferredAudio) { category in
                guard let servers = options[category], !servers.isEmpty else {
                    print("No servers available for selected category")
                    DispatchQueue.main.async {
                        self.showAlert(title: "Error", message: "No server available")
                    }
                    return
                }
                
                self.selectServer(servers: servers, preferredServer: preferredServer) { server in
                    let finalURL = "https://aniwatch-api-dusky.vercel.app/anime/episode-srcs?id=\(episodeId)&category=\(category)&server=\(server)"
                    print(finalURL)
                    
                    self.fetchHiAnimeData(from: finalURL) { sourceURL, captionURLs in
                        DispatchQueue.main.async {
                            guard let sourceURL = sourceURL else {
                                print("Error extracting source URL")
                                self.showAlert(title: "Error", message: "Error extracting source URL")
                                return
                            }
                            
                            self.selectSubtitles(captionURLs: captionURLs) { selectedSubtitleURL in
                                let subtitleURL = selectedSubtitleURL ?? URL(string: "https://nosubtitlesfor.you")!
                                self.openHiAnimeExperimental(url: sourceURL, subURL: subtitleURL, cell: cell, fullURL: fullURL)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func selectAudioCategory(options: [String: [[String: Any]]], preferredAudio: String, completion: @escaping (String) -> Void) {
        if let audioOptions = options[preferredAudio], !audioOptions.isEmpty {
            completion(preferredAudio)
        } else {
            DispatchQueue.main.async {
                self.presentDubSubSelection(options: options, completion: completion)
            }
        }
    }
    
    private func selectServer(servers: [[String: Any]], preferredServer: String, completion: @escaping (String) -> Void) {
        if let server = servers.first(where: { ($0["serverName"] as? String) == preferredServer }) {
            completion(server["serverName"] as? String ?? "")
        } else {
            DispatchQueue.main.async {
                self.presentServerSelection(servers: servers, completion: completion)
            }
        }
    }
    
    private func selectSubtitles(captionURLs: [String: URL]?, completion: @escaping (URL?) -> Void) {
        guard let captionURLs = captionURLs, !captionURLs.isEmpty else {
            completion(nil)
            return
        }
        
        if let preferredSubtitles = UserDefaults.standard.string(forKey: "subtitleHiPrefe"),
           let preferredURL = captionURLs[preferredSubtitles] {
            completion(preferredURL)
        } else {
            DispatchQueue.main.async {
                self.presentSubtitleSelection(captionURLs: captionURLs, completion: completion)
            }
        }
    }
    
    private func presentSubtitleSelection(captionURLs: [String: URL], completion: @escaping (URL?) -> Void) {
        let alert = UIAlertController(title: "Select Subtitle Language", message: nil, preferredStyle: .actionSheet)
        
        for (label, url) in captionURLs {
            alert.addAction(UIAlertAction(title: label, style: .default) { _ in
                completion(url)
            })
        }
        
        alert.addAction(UIAlertAction(title: "No Subtitles", style: .default) { _ in
            completion(nil)
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let topController = scene.windows.first?.rootViewController {
            if UIDevice.current.userInterfaceIdiom == .pad {
                alert.modalPresentationStyle = .popover
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = topController.view
                    popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
            }
            topController.present(alert, animated: true, completion: nil)
        }
    }
    
    private func handleSources(url: String, cell: EpisodeCell, fullURL: String) {
        guard let requestURL = URL(string: url) else {
            DispatchQueue.main.async {
                self.showAlert(title: "Error", message: "Invalid URL: \(url)")
            }
            return
        }
        
        URLSession.shared.dataTask(with: requestURL) { [weak self] (data, response, error) in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    self.showAlert(title: "Error", message: "Error fetching video data: \(error.localizedDescription)")
                    return
                }
                
                guard let data = data, let htmlString = String(data: data, encoding: .utf8) else {
                    self.showAlert(title: "Error", message: "Error parsing video data")
                    return
                }
                
                let selectedMediaSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
                var srcURL: URL?
                
                switch selectedMediaSource {
                case "GoGoAnime":
                    srcURL = self.extractIframeSourceURL(from: htmlString)
                case "ZoroTv":
                    self.extractIframeAndGetM3U8URL(from: htmlString, cell: cell, fullURL: fullURL) { [weak self] result in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            guard let m3u8URL = result else {
                                print("Error getting the video URL")
                                self.showAlert(title: "Error", message: "Error getting the video URL")
                                return
                            }
                            self.playVideo(sourceURL: m3u8URL, cell: cell, fullURL: fullURL)
                        }
                    }
                    return
                case "AnimeFire":
                    srcURL = self.extractDataVideoSrcURL(from: htmlString)
                case "AnimeWorld", "AnimeHeaven":
                    srcURL = self.extractVideoSourceURL(from: htmlString)
                case "Anime3rb", "Kuramanime", "JKanime":
                    srcURL = URL(string: fullURL)
                default:
                    srcURL = self.extractIframeSourceURL(from: htmlString)
                }
                
                guard let finalSrcURL = srcURL else {
                    print("Error extracting source URL")
                    self.showAlert(title: "Error", message: "Error extracting source URL")
                    return
                }
                
                DispatchQueue.main.async {
                    switch selectedMediaSource {
                    case "GoGoAnime":
                        self.startStreamingButtonTapped(withURL: finalSrcURL.absoluteString, captionURL: "", playerType: VideoPlayerType.standard, cell: cell, fullURL: fullURL)
                    case "AnimeFire":
                        self.fetchVideoDataAndChooseQuality(from: finalSrcURL.absoluteString) { selectedURL in
                            guard let selectedURL = selectedURL else { return }
                            self.playVideo(sourceURL: selectedURL, cell: cell, fullURL: fullURL)
                        }
                    case "Anime3rb":
                        self.startStreamingButtonTapped(withURL: finalSrcURL.absoluteString, captionURL: "", playerType: VideoPlayerType.player3rb, cell: cell, fullURL: fullURL)
                    case "Kuramanime":
                        self.startStreamingButtonTapped(withURL: finalSrcURL.absoluteString, captionURL: "", playerType: VideoPlayerType.playerKura, cell: cell, fullURL: fullURL)
                    case "JKanime":
                        self.startStreamingButtonTapped(withURL: finalSrcURL.absoluteString, captionURL: "", playerType: VideoPlayerType.playerJK, cell: cell, fullURL: fullURL)
                    default:
                        self.playVideo(sourceURL: finalSrcURL, cell: cell, fullURL: fullURL)
                    }
                }
            }
        }.resume()
    }
    
    func extractIframeAndGetM3U8URL(from htmlString: String, cell: EpisodeCell, fullURL: String, completion: @escaping (URL?) -> Void) {
        do {
            let doc = try SwiftSoup.parse(htmlString)
            
            guard let iframeElement = try doc.select("iframe").first() else {
                print("No iframe element found in the HTML.")
                completion(nil)
                return
            }
            
            guard let sourceURLString = try iframeElement.attr("src").nilIfEmpty else {
                print("Iframe src attribute not found.")
                completion(nil)
                return
            }
            
            var sourceURL = URL(string: sourceURLString)
            if sourceURL?.scheme != "https" {
                sourceURL = URL(string: "https:\(sourceURLString)")
            }
            
            guard let sourceURL = sourceURL else {
                completion(nil)
                return
            }
            
            let task = URLSession.shared.dataTask(with: sourceURL) { [weak self] (data, response, error) in
                guard let self = self else { return }
                
                if let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) {
                    if let m3u8URLString = String(data: data ?? Data(), encoding: .utf8)?
                        .components(separatedBy: "\"")
                        .first(where: { $0.contains(".m3u8") }) {
                        if let m3u8URL = URL(string: m3u8URLString.replacingOccurrences(of: "\\", with: "")) {
                            let selectedPlayer = UserDefaults.standard.string(forKey: "mediaPlayerSelected") ?? "Default"
                            
                            if selectedPlayer == "Experimental" {
                                DispatchQueue.main.async {
                                    self.openVideo(url: m3u8URL, cell: cell, fullURL: fullURL)
                                }
                            } else {
                                self.loadQualityOptions(from: m3u8URL) { success, error in
                                    if success {
                                        DispatchQueue.main.async {
                                            self.showQualitySelection { selectedURL in
                                                completion(selectedURL)
                                            }
                                        }
                                    } else {
                                        print("Failed to load quality options: \(error?.localizedDescription ?? "Unknown error")")
                                        DispatchQueue.main.async {
                                            self.showAlert(title: "Error", message: "Failed to load quality options")
                                        }
                                        completion(nil)
                                    }
                                }
                            }
                        } else {
                            completion(nil)
                        }
                    } else {
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            }
            task.resume()
        } catch {
            completion(nil)
        }
    }
    
    func openVideo(url: URL, cell: EpisodeCell, fullURL: String) {
        let videoTitle = animeTitle!
        let viewController = CustomPlayerView(videoTitle: videoTitle, videoURL: url, cell: cell, fullURL: fullURL)
        viewController.modalPresentationStyle = .fullScreen
        self.present(viewController, animated: true, completion: nil)
    }
    
    func loadQualityOptions(from url: URL, completion: @escaping (Bool, Error?) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error downloading m3u8 file: \(error)")
                DispatchQueue.main.async {
                    completion(false, error)
                }
                return
            }
            
            guard let data = data,
                  let m3u8Content = String(data: data, encoding: .utf8) else {
                      print("Failed to decode m3u8 file content")
                      let error = NSError(domain: "M3U8ErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse m3u8 file"])
                      DispatchQueue.main.async {
                          completion(false, error)
                      }
                      return
                  }
            
            print("m3u8 file content:\n\(m3u8Content)")
            
            let lines = m3u8Content.components(separatedBy: .newlines)
            var currentName: String?
            var newQualityOptions: [(name: String, fileName: String)] = []
            
            for line in lines {
                if line.hasPrefix("#EXT-X-STREAM-INF") {
                    if let nameRange = line.range(of: "NAME=\"") {
                        let nameStartIndex = line.index(nameRange.upperBound, offsetBy: 0)
                        if let nameEndIndex = line[nameStartIndex...].firstIndex(of: "\"") {
                            currentName = String(line[nameStartIndex..<nameEndIndex])
                        }
                    }
                } else if line.hasSuffix(".m3u8"), let name = currentName {
                    let fullURL = URL(string: line, relativeTo: url)?.absoluteString ?? line
                    newQualityOptions.append((name: name, fileName: fullURL))
                    currentName = nil
                }
            }
            
            self.qualityOptions = newQualityOptions
            print("Parsed quality options: \(self.qualityOptions)")
            
            DispatchQueue.main.async {
                completion(true, nil)
            }
        }
        task.resume()
    }
    
    func showQualitySelection(completion: @escaping (URL?) -> Void) {
        let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality")
        
        if let preferredQuality = preferredQuality {
            if let exactMatch = qualityOptions.first(where: { $0.name == preferredQuality }) {
                handleQualitySelection(option: exactMatch, completion: completion)
                return
            }
            let closestMatch = findClosestQuality(to: preferredQuality)
            if let closestMatch = closestMatch {
                handleQualitySelection(option: closestMatch, completion: completion)
                return
            }
        }
        
        presentQualityPicker(completion: completion)
    }
    
    private func findClosestQuality(to preferredQuality: String) -> (name: String, fileName: String)? {
        let preferredValue = extractQualityValue(from: preferredQuality)
        var closestOption: (name: String, fileName: String)?
        var smallestDifference = Int.max
        
        for option in qualityOptions {
            let optionValue = extractQualityValue(from: option.name)
            let difference = abs(preferredValue - optionValue)
            if difference < smallestDifference {
                smallestDifference = difference
                closestOption = option
            }
        }
        
        return closestOption
    }
    
    private func extractQualityValue(from qualityString: String) -> Int {
        return Int(qualityString.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
    }
    
    private func handleQualitySelection(option: (name: String, fileName: String), completion: @escaping (URL?) -> Void) {
        if let url = URL(string: option.fileName) {
            completion(url)
        } else {
            completion(nil)
        }
    }
    
    private func presentQualityPicker(completion: @escaping (URL?) -> Void) {
        let alert = UIAlertController(title: "Select Quality", message: nil, preferredStyle: .actionSheet)
        
        for option in qualityOptions {
            alert.addAction(UIAlertAction(title: option.name, style: .default, handler: { _ in
                self.handleQualitySelection(option: option, completion: completion)
            }))
        }
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = self.view
                popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        
        self.present(alert, animated: true, completion: nil)
    }
    
    func extractEpisodeId(from url: String) -> String? {
        let components = url.components(separatedBy: "?")
        guard components.count >= 2 else { return nil }
        let episodeId = components[1].components(separatedBy: "&").first
        guard let ep = components.last else { return nil }
        
        return episodeId.flatMap { "\($0)?\(ep)" }
    }
    
    func fetchEpisodeOptions(episodeId: String, completion: @escaping ([String: [[String: Any]]]) -> Void) {
        let url = URL(string: "https://aniwatch-api-dusky.vercel.app/anime/servers?episodeId=\(episodeId)")!
        print(url)
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data else {
                print("Error fetching episode options: \(error?.localizedDescription ?? "Unknown error")")
                completion([:])
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let raw = json["raw"] as? [[String: Any]],
                   let sub = json["sub"] as? [[String: Any]],
                   let dub = json["dub"] as? [[String: Any]] {
                    completion(["raw": raw,"sub": sub, "dub": dub])
                } else {
                    completion([:])
                }
            } catch {
                print("Error parsing episode options: \(error.localizedDescription)")
                completion([:])
            }
        }.resume()
    }
    
    func presentDubSubSelection(options: [String: [[String: Any]]], completion: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            let rawOptions = options["raw"]
            let subOptions = options["sub"]
            let dubOptions = options["dub"]
            
            if let rawOptions = rawOptions, !rawOptions.isEmpty,
               let subOptions = subOptions, !subOptions.isEmpty,
               let dubOptions = dubOptions, !dubOptions.isEmpty {
                let alert = UIAlertController(title: "Select Audio", message: nil, preferredStyle: .actionSheet)
                
                alert.addAction(UIAlertAction(title: "Raw", style: .default) { _ in
                    completion("raw")
                })
                
                alert.addAction(UIAlertAction(title: "Subtitled", style: .default) { _ in
                    completion("sub")
                })
                
                alert.addAction(UIAlertAction(title: "Dubbed", style: .default) { _ in
                    completion("dub")
                })
                
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let topController = scene.windows.first?.rootViewController {
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        alert.modalPresentationStyle = .popover
                        if let popover = alert.popoverPresentationController {
                            popover.sourceView = topController.view
                            popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                            popover.permittedArrowDirections = []
                        }
                    }
                    topController.present(alert, animated: true, completion: nil)
                } else {
                    print("Could not find top view controller to present alert")
                }
            } else if let subOptions = subOptions, !subOptions.isEmpty {
                completion("sub")
            } else if let dubOptions = dubOptions, !dubOptions.isEmpty {
                completion("dub")
            } else if let rawOptions = rawOptions, !rawOptions.isEmpty {
                completion("raw")
            } else {
                print("No audio options available")
                self.showAlert(title: "Error", message: "No audio options available")
            }
        }
    }
    
    func presentServerSelection(servers: [[String: Any]], completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: "Select Server", message: nil, preferredStyle: .actionSheet)
        
        for server in servers {
            if let serverName = server["serverName"] as? String,
               serverName != "streamtape" && serverName != "streamsb" {
                alert.addAction(UIAlertAction(title: serverName, style: .default) { _ in
                    completion(serverName)
                })
            }
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let topController = scene.windows.first?.rootViewController {
            if UIDevice.current.userInterfaceIdiom == .pad {
                alert.modalPresentationStyle = .popover
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = topController.view
                    popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
            }
            topController.present(alert, animated: true, completion: nil)
        }
    }
    
    private func fetchHiAnimeData(from fullURL: String, completion: @escaping (URL?, [String: URL]?) -> Void) {
        guard let url = URL(string: fullURL) else {
            print("Invalid URL for HiAnime: \(fullURL)")
            completion(nil, nil)
            return
        }
        
        URLSession.shared.dataTask(with: url) { (data, response, error) in
            if let error = error {
                print("Error fetching HiAnime data: \(error.localizedDescription)")
                completion(nil, nil)
                return
            }
            
            guard let data = data else {
                print("Error: No data received from HiAnime")
                completion(nil, nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    var captionURLs: [String: URL] = [:]
                    
                    if let tracks = json["tracks"] as? [[String: Any]] {
                        for track in tracks {
                            if let file = track["file"] as? String, let label = track["label"] as? String, track["kind"] as? String == "captions" {
                                captionURLs[label] = URL(string: file)
                            }
                        }
                    }
                    
                    var sourceURL: URL?
                    if let sources = json["sources"] as? [[String: Any]] {
                        if let source = sources.first, let urlString = source["url"] as? String {
                            sourceURL = URL(string: urlString)
                        }
                    }
                    
                    completion(sourceURL, captionURLs)
                }
            } catch {
                print("Error parsing HiAnime JSON: \(error.localizedDescription)")
                completion(nil, nil)
            }
        }.resume()
    }
    
    private func fetchHTMLContent(from url: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: url) else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data, let htmlString = String(data: data, encoding: .utf8) else {
                completion(.failure(NSError(domain: "Invalid data", code: 0, userInfo: nil)))
                return
            }
            
            completion(.success(htmlString))
        }.resume()
    }
    
    private func proceedWithCasting(videoURL: URL) {
        DispatchQueue.main.async {
            let metadata = GCKMediaMetadata(metadataType: .movie)
            
            if UserDefaults.standard.bool(forKey: "fullTitleCast") {
                if let animeTitle = self.animeTitle {
                    metadata.setString(animeTitle, forKey: kGCKMetadataKeyTitle)
                } else {
                    print("Error: Anime title is missing.")
                }
            } else {
                let episodeNumber = self.currentEpisodeIndex + 1
                metadata.setString("Episode \(episodeNumber)", forKey: kGCKMetadataKeyTitle)
            }
            
            if UserDefaults.standard.bool(forKey: "animeImageCast") {
                if let imageURL = URL(string: self.imageUrl ?? "") {
                    metadata.addImage(GCKImage(url: imageURL, width: 480, height: 720))
                } else {
                    print("Error: Anime image URL is missing or invalid.")
                }
            }
            
            let builder = GCKMediaInformationBuilder(contentURL: videoURL)
            
            let contentType: String
            
            if videoURL.absoluteString.contains(".m3u8") {
                contentType = "application/x-mpegurl"
            } else if videoURL.absoluteString.contains(".mp4") {
                contentType = "video/mp4"
            } else {
                contentType = "video/mp4"
            }
            
            builder.contentType = contentType
            builder.metadata = metadata
            
            let streamTypeString = UserDefaults.standard.string(forKey: "castStreamingType") ?? "buffered"
            switch streamTypeString {
            case "live":
                builder.streamType = .live
            default:
                builder.streamType = .buffered
            }
            
            let mediaInformation = builder.build()
            
            let mediaLoadOptions = GCKMediaLoadOptions()
            mediaLoadOptions.autoplay = true
            mediaLoadOptions.playPosition = 0
            
            if let castSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
               let remoteMediaClient = castSession.remoteMediaClient {
                remoteMediaClient.loadMedia(mediaInformation, with: mediaLoadOptions)
                remoteMediaClient.add(self)
            } else {
                print("Error: Failed to load media to Google Cast")
            }
        }
    }
    
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        if let mediaStatus = mediaStatus, mediaStatus.idleReason == .finished {
            if UserDefaults.standard.bool(forKey: "AutoPlay") {
                DispatchQueue.main.async { [weak self] in
                    self?.playNextEpisode()
                }
            }
        }
    }
    
    private func extractVideoSourceURL(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            guard let videoElement = try doc.select("video").first(),
                  let sourceElement = try videoElement.select("source").first(),
                  let sourceURLString = try sourceElement.attr("src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      return nil
                  }
            return sourceURL
        } catch {
            print("Error parsing HTML with SwiftSoup: \(error)")
            
            let mp4Pattern = #"<source src="(.*?)" type="video/mp4">"#
            let m3u8Pattern = #"<source src="(.*?)" type="application/x-mpegURL">"#
            
            if let mp4URL = extractURL(from: htmlString, pattern: mp4Pattern) {
                return mp4URL
            } else if let m3u8URL = extractURL(from: htmlString, pattern: m3u8Pattern) {
                return m3u8URL
            }
            return nil
        }
    }
    
    private func extractURL(from htmlString: String, pattern: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
              let urlRange = Range(match.range(at: 1), in: htmlString) else {
                  return nil
              }
        
        let urlString = String(htmlString[urlRange])
        return URL(string: urlString)
    }
    
    private func extractIframeSourceURL(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            guard let iframeElement = try doc.select("iframe").first(),
                  let sourceURLString = try iframeElement.attr("src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      return nil
                  }
            print("Iframe src URL: \(sourceURL.absoluteString)")
            return sourceURL
        } catch {
            print("Error parsing HTML with SwiftSoup: \(error)")
            return nil
        }
    }
    
    private func extractDataVideoSrcURL(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            guard let element = try doc.select("[data-video-src]").first(),
                  let sourceURLString = try element.attr("data-video-src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      return nil
                  }
            print("Data-video-src URL: \(sourceURL.absoluteString)")
            return sourceURL
        } catch {
            print("Error parsing HTML with SwiftSoup: \(error)")
            return nil
        }
    }
    
    private func fetchVideoDataAndChooseQuality(from urlString: String, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: urlString) else {
            print("Invalid URL string")
            completion(nil)
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                print("Network error: \(String(describing: error))")
                completion(nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let videoDataArray = json["data"] as? [[String: Any]] {
                    
                    self.availableQualities.removeAll()
                    
                    for videoData in videoDataArray {
                        if let label = videoData["label"] as? String {
                            self.availableQualities.append(label)
                        }
                    }
                    
                    if self.availableQualities.isEmpty {
                        print("No available video qualities found")
                        completion(nil)
                        return
                    }
                    
                    DispatchQueue.main.async {
                        self.choosePreferredQuality(availableQualities: self.availableQualities, videoDataArray: videoDataArray, completion: completion)
                    }
                    
                } else {
                    print("JSON structure is invalid or data key is missing")
                    completion(nil)
                }
            } catch {
                print("Error parsing JSON: \(error)")
                completion(nil)
            }
        }
        
        task.resume()
    }
    
    private func choosePreferredQuality(availableQualities: [String], videoDataArray: [[String: Any]], completion: @escaping (URL?) -> Void) {
        let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "1080p"
        
        var selectedQuality: String? = nil
        var closestQuality: String? = nil
        
        for quality in availableQualities {
            if quality == preferredQuality {
                selectedQuality = quality
                break
            } else if closestQuality == nil || abs(preferredQuality.compare(quality).rawValue) < abs(preferredQuality.compare(closestQuality!).rawValue) {
                closestQuality = quality
            }
        }
        
        let finalSelectedQuality = selectedQuality ?? closestQuality
        
        if let finalQuality = finalSelectedQuality,
           let selectedVideoData = videoDataArray.first(where: { $0["label"] as? String == finalQuality }),
           let selectedURLString = selectedVideoData["src"] as? String,
           let selectedURL = URL(string: selectedURLString) {
            completion(selectedURL)
        } else {
            print("No suitable quality option found")
            completion(nil)
        }
    }
    
    private func showQualityPicker(qualities: [String], completion: @escaping (String?) -> Void) {
        let alertController = UIAlertController(title: "Choose Video Quality", message: nil, preferredStyle: .actionSheet)
        
        for quality in qualities {
            let action = UIAlertAction(title: quality, style: .default) { _ in
                completion(quality)
            }
            alertController.addAction(action)
        }
        
        if let popoverController = alertController.popoverPresentationController {
            popoverController.sourceView = view
            popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = []
        }
        
        present(alertController, animated: true, completion: nil)
    }
    
    func playVideo(sourceURL: URL, cell: EpisodeCell, fullURL: String) {
        let selectedPlayer = UserDefaults.standard.string(forKey: "mediaPlayerSelected") ?? "Default"
        let isToDownload = UserDefaults.standard.bool(forKey: "isToDownload")
        
        if isToDownload {
            handleDownload(sourceURL: sourceURL, fullURL: fullURL)
        } else {
            DispatchQueue.main.async {
                self.playVideoWithSelectedPlayer(player: selectedPlayer, sourceURL: sourceURL, cell: cell, fullURL: fullURL)
            }
        }
    }
    
    private func handleDownload(sourceURL: URL, fullURL: String) {
        UserDefaults.standard.set(false, forKey: "isToDownload")
        
        guard let episode = episodes.first(where: { $0.href == fullURL }) else {
            print("Error: Could not find episode for URL \(fullURL)")
            return
        }
        
        let downloadManager = DownloadManager.shared
        let title = "\(self.animeTitle ?? "Anime") - Ep. \(episode.number)"
        
        self.showAlert(title: "Download", message: "Your download has started!")
        
        downloadManager.startDownload(url: sourceURL, title: title, progress: { progress in
            print("Download progress: \(progress * 100)%")
        }) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleDownloadResult(result)
            }
        }
    }
    
    private func handleDownloadResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            print("Download completed. File saved at: \(url)")
        case .failure(let error):
            print("Download failed with error: \(error.localizedDescription)")
        }
    }
    
    private func playVideoWithSelectedPlayer(player: String, sourceURL: URL, cell: EpisodeCell, fullURL: String) {
        switch player {
        case "Infuse", "VLC", "OutPlayer":
            openInExternalPlayer(player: player, url: sourceURL)
        case "Experimental":
            let videoTitle = animeTitle
            let viewController = CustomPlayerView(videoTitle: videoTitle ?? "", videoURL: sourceURL, cell: cell, fullURL: fullURL)
            viewController.modalPresentationStyle = .fullScreen
            self.present(viewController, animated: true, completion: nil)
        default:
            playVideoWithAVPlayer(sourceURL: sourceURL, cell: cell, fullURL: fullURL)
        }
    }
    
    func openInExternalPlayer(player: String, url: URL) {
        var scheme: String
        switch player {
        case "Infuse":
            scheme = "infuse://x-callback-url/play?url="
        case "VLC":
            scheme = "vlc://"
        case "OutPlayer":
            scheme = "outplayer://"
        default:
            print("Unsupported player")
            showAlert(title: "Error", message: "Unsupported player")
            return
        }
        
        guard let playerURL = URL(string: scheme + url.absoluteString) else {
            print("Failed to create \(player) URL")
            return
        }
        
        if UIApplication.shared.canOpenURL(playerURL) {
            UIApplication.shared.open(playerURL, options: [:], completionHandler: nil)
        } else {
            print("\(player) app is not installed")
            showAlert(title: "\(player) Error", message: "\(player) app is not installed.")
        }
    }
    
    func openHiAnimeExperimental(url: URL, subURL: URL, cell: EpisodeCell, fullURL: String) {
        let videoTitle = animeTitle!
        let viewController = CustomPlayerView(videoTitle: videoTitle, videoURL: url, cell: cell, fullURL: fullURL)
        viewController.modalPresentationStyle = .fullScreen
        self.present(viewController, animated: true, completion: nil)
    }
    
    private func playVideoWithAVPlayer(sourceURL: URL, cell: EpisodeCell, fullURL: String) {
        if GCKCastContext.sharedInstance().castState == .connected {
            proceedWithCasting(videoURL: sourceURL)
        } else {
            player = AVPlayer(url: sourceURL)
            
            playerViewController = UserDefaults.standard.bool(forKey: "AlwaysLandscape") ? LandscapePlayer() : NormalPlayer()
            playerViewController?.player = player
            playerViewController?.delegate = self
            playerViewController?.entersFullScreenWhenPlaybackBegins = true
            playerViewController?.showsPlaybackControls = true
            
            let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(fullURL)")
            
            playerViewController?.modalPresentationStyle = .fullScreen
            present(playerViewController!, animated: true) {
                if lastPlayedTime > 0 {
                    let seekTime = CMTime(seconds: lastPlayedTime, preferredTimescale: 1)
                    self.player?.seek(to: seekTime) { _ in
                        self.player?.play()
                    }
                } else {
                    self.player?.play()
                }
                self.addPeriodicTimeObserver(cell: cell, fullURL: fullURL)
            }
            
            NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd), name: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
        }
    }
    
    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if self.presentedViewController == nil {
            playerViewController.modalPresentationStyle = .fullScreen
            present(playerViewController, animated: true) {
                completionHandler(true)
            }
        } else {
            completionHandler(true)
        }
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            try audioSession.setActive(true)
            
            try audioSession.overrideOutputAudioPort(.speaker)
        } catch {
            print("Failed to set up AVAudioSession: \(error)")
        }
    }
    
    private func addPeriodicTimeObserver(cell: EpisodeCell, fullURL: String) {
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let currentItem = self.player?.currentItem,
                  currentItem.duration.seconds.isFinite else {
                      return
                  }
            
            let currentTime = time.seconds
            let duration = currentItem.duration.seconds
            let progress = currentTime / duration
            let remainingTime = duration - currentTime
            
            cell.updatePlaybackProgress(progress: Float(progress), remainingTime: remainingTime)
            
            UserDefaults.standard.set(currentTime, forKey: "lastPlayedTime_\(fullURL)")
            UserDefaults.standard.set(duration, forKey: "totalTime_\(fullURL)")
            
            let episodeNumber = Int(cell.episodeNumber) ?? 0
            let selectedMediaSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? "AnimeWorld"
            
            let continueWatchingItem = ContinueWatchingItem(
                animeTitle: self.animeTitle ?? "Unknown Anime",
                episodeTitle: "Ep. \(episodeNumber)",
                episodeNumber: episodeNumber,
                imageURL: self.imageUrl ?? "",
                fullURL: fullURL,
                lastPlayedTime: currentTime,
                totalTime: duration,
                source: selectedMediaSource
            )
            ContinueWatchingManager.shared.saveItem(continueWatchingItem)
            
            let shouldSendPushUpdates = UserDefaults.standard.bool(forKey: "sendPushUpdates")
            
            if shouldSendPushUpdates && remainingTime < 120 && !self.hasSentUpdate {
                let cleanedTitle = self.cleanTitle(self.animeTitle ?? "Unknown Anime")
                
                self.fetchAnimeID(title: cleanedTitle) { animeID in
                    let aniListMutation = AniListMutation()
                    aniListMutation.updateAnimeProgress(animeId: animeID, episodeNumber: episodeNumber) { result in
                        switch result {
                        case .success():
                            print("Successfully updated anime progress.")
                        case .failure(let error):
                            print("Failed to update anime progress: \(error.localizedDescription)")
                        }
                    }
                    
                    self.hasSentUpdate = true
                }
            }
        }
    }
    
    func fetchAnimeID(title: String, completion: @escaping (Int) -> Void) {
        if let animeTitle = self.animeTitle {
            let customID = UserDefaults.standard.string(forKey: "customAniListID_\(animeTitle)")
            
            if let customID = customID, let id = Int(customID) {
                completion(id)
                return
            }
        }
        
        AnimeService.fetchAnimeID(byTitle: title) { result in
            switch result {
            case .success(let id):
                completion(id)
            case .failure(let error):
                print("Error fetching anime ID: \(error.localizedDescription)")
            }
        }
    }
    
    func playNextEpisode() {
        if isReverseSorted {
            currentEpisodeIndex -= 1
            if currentEpisodeIndex >= 0 {
                let nextEpisode = episodes[currentEpisodeIndex]
                if let cell = tableView.cellForRow(at: IndexPath(row: currentEpisodeIndex, section: 2)) as? EpisodeCell {
                    episodeSelected(episode: nextEpisode, cell: cell)
                }
            } else {
                currentEpisodeIndex = 0
            }
        } else {
            currentEpisodeIndex += 1
            if currentEpisodeIndex < episodes.count {
                let nextEpisode = episodes[currentEpisodeIndex]
                if let cell = tableView.cellForRow(at: IndexPath(row: currentEpisodeIndex, section: 2)) as? EpisodeCell {
                    episodeSelected(episode: nextEpisode, cell: cell)
                }
            } else {
                currentEpisodeIndex = episodes.count - 1
            }
        }
    }
    
    @objc func playerItemDidReachEnd(notification: Notification) {
        if UserDefaults.standard.bool(forKey: "AutoPlay") {
            let hasNextEpisode = isReverseSorted ? (currentEpisodeIndex > 0) : (currentEpisodeIndex < episodes.count - 1)
            if hasNextEpisode {
                playerViewController?.dismiss(animated: true) { [weak self] in
                    self?.playNextEpisode()
                }
            } else {
                playerViewController?.dismiss(animated: true, completion: nil)
            }
        } else {
            playerViewController?.dismiss(animated: true, completion: nil)
        }
    }
    
    func downloadMedia(for episode: Episode) {
        guard let cell = tableView.cellForRow(at: IndexPath(row: episodes.firstIndex(where: { $0.href == episode.href }) ?? 0, section: 2)) as? EpisodeCell else {
            print("Error: Could not get cell for episode \(episode.number)")
            return
        }
        
        UserDefaults.standard.set(true, forKey: "isToDownload")
        
        episodeSelected(episode: episode, cell: cell)
    }
}

extension AnimeDetailViewController: SynopsisCellDelegate {
    func synopsisCellDidToggleExpansion(_ cell: SynopsisCell) {
        isSynopsisExpanded.toggle()
        tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
    }
}

class ContinueWatchingCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let progressView = UIProgressView()
    private let blurEffectView: UIVisualEffectView = {
        let effect = UIBlurEffect(style: .dark)
        let blurEffectView = UIVisualEffectView(effect: effect)
        blurEffectView.alpha = 0.75
        return blurEffectView
    }()
    
    private var imageLoadTask: DownloadTask?
    private var currentAnimeTitle: String?
    private var currentEpisodeNumber: Int?
    
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageView.image = nil
        titleLabel.text = nil
        progressView.progress = 0
        currentAnimeTitle = nil
        currentEpisodeNumber = nil
    }
    
    private func setupViews() {
        contentView.addSubview(imageView)
        contentView.addSubview(titleLabel)
        imageView.addSubview(blurEffectView)
        imageView.addSubview(progressView)
        
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        titleLabel.numberOfLines = 2
        titleLabel.textColor = .white
        titleLabel.textAlignment = .left
        
        progressView.progressTintColor = .systemTeal
        
        imageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        blurEffectView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: 300),
            contentView.heightAnchor.constraint(equalToConstant: 120),
            
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 0.6),
            
            blurEffectView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            blurEffectView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            blurEffectView.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            blurEffectView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            
            progressView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 8),
            progressView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -8),
            progressView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -4),
            progressView.heightAnchor.constraint(equalToConstant: 6),
            
            titleLabel.bottomAnchor.constraint(equalTo: progressView.topAnchor, constant: -4),
            titleLabel.trailingAnchor.constraint(equalTo: progressView.trailingAnchor),
            titleLabel.widthAnchor.constraint(equalTo: progressView.widthAnchor)
        ])
    }
    
    private func getPlaceholderImage() -> UIImage {
        UIImage(systemName: "photo.fill")?.withTintColor(.gray, renderingMode: .alwaysOriginal) ?? UIImage()
    }
    
    private func getErrorPlaceholderImage() -> UIImage {
        UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.red, renderingMode: .alwaysOriginal) ?? UIImage()
    }
    
    func configure(with item: ContinueWatchingItem) {
        titleLabel.text = "\(item.animeTitle), Ep. \(item.episodeNumber)"
        progressView.progress = Float(item.lastPlayedTime / item.totalTime)
        
        currentAnimeTitle = item.animeTitle
        currentEpisodeNumber = item.episodeNumber
        
        imageView.image = getPlaceholderImage()
        
        AnimeThumbnailFetcher.fetchAnimeThumbnails(for: item.animeTitle, episodeNumber: item.episodeNumber) { [weak self] imageURL in
            guard let self = self,
                  let imageURL = imageURL,
                  self.currentAnimeTitle == item.animeTitle,
                  self.currentEpisodeNumber == item.episodeNumber else {
                      return
                  }
            
            if let url = URL(string: imageURL) {
                self.imageLoadTask = self.imageView.kf.setImage(
                    with: url,
                    placeholder: self.getPlaceholderImage(),
                    options: [
                        .transition(.fade(0.2)),
                        .cacheOriginalImage
                    ]
                ) { result in
                    switch result {
                    case .success(_):
                        break
                    case .failure(let error):
                        print("Error loading image: \(error)")
                        self.imageView.image = self.getErrorPlaceholderImage()
                    }
                }
            }
        }
    }
}

class AnimeThumbnailFetcher {
    static let apiUrl = "https://api.ani.zip/mappings?anilist_id="
    
    static func fetchAnimeThumbnails(for title: String, episodeNumber: Int, completion: @escaping (String?) -> Void) {
        fetchAnimeID(for: title) { anilistId in
            guard let anilistId = anilistId else {
                completion(nil)
                return
            }
            
            let url = URL(string: "\(self.apiUrl)\(anilistId)")!
            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                if let error = error {
                    print("Error fetching anime thumbnails: \(error)")
                    completion(nil)
                    return
                }
                
                guard let data = data else {
                    completion(nil)
                    return
                }
                
                do {
                    let json = try JSONSerialization.jsonObject(with: data, options: [])
                    if let jsonDict = json as? [String: Any],
                       let episodes = jsonDict["episodes"] as? [String: Any],
                       let episodeInfo = episodes["\(episodeNumber)"] as? [String: Any],
                       let imageUrl = episodeInfo["image"] as? String {
                        completion(imageUrl)
                    } else {
                        completion(nil)
                    }
                } catch {
                    print("Error parsing JSON: \(error)")
                    completion(nil)
                }
            }
            task.resume()
        }
    }
    
    static func fetchAnimeID(for title: String, completion: @escaping (Int?) -> Void) {
        if let customID = UserDefaults.standard.string(forKey: "customAniListID_\(title)"),
           let id = Int(customID) {
            completion(id)
            return
        }
        
        let cleanedTitle = cleanTitle(title: title)
        AnimeService.fetchAnimeID(byTitle: cleanedTitle) { result in
            switch result {
            case .success(let id):
                completion(id)
            case .failure(let error):
                print("Error fetching anime ID: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }
    
    static func cleanTitle(title: String) -> String {
        let unwantedStrings = ["(ITA)", "(Dub)", "(Dub ID)", "(Dublado)"]
        var cleanedTitle = title
        
        for unwanted in unwantedStrings {
            cleanedTitle = cleanedTitle.replacingOccurrences(of: unwanted, with: "")
        }
        
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "\"", with: "")
        return cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
