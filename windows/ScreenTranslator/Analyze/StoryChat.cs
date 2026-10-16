using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Hội thoại hỏi đáp về cốt truyện của mục "Hỏi đáp". Chỉ giữ trong RAM, riêng cho từng game, mất khi thoát app. Dùng trên UI thread.
public sealed class StoryChat : INotifyPropertyChanged
{
    public static readonly StoryChat shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

    public sealed class Turn
    {
        public string question = "";
        public string? answer, error;
        public BackendKind? backend;
        public int ms;
    }

    readonly Dictionary<string, List<Turn>> byProfile = new();
    bool _running;
    public bool isRunning { get => _running; private set { _running = value; Raise(nameof(isRunning)); } }

    static string Profile => HistoryStore.ProfileKey(AppSettings.shared.activeProfile.id);
    public IReadOnlyList<Turn> turns => byProfile.TryGetValue(Profile, out var t) ? t : Array.Empty<Turn>();

    public void Clear()
    {
        byProfile.Remove(Profile);
        Raise(nameof(turns));
    }

    public async void Ask(string text)
    {
        var question = text.Trim();
        if (question.Length > StoryQA.maxQuestion) question = question[..StoryQA.maxQuestion];
        if (question.Length == 0 || isRunning) return;
        var history = turns.Where(t => t.answer != null).Select(t => new StoryQA.Turn(t.question, t.answer!)).ToList();
        var turn = new Turn { question = question };
        var profile = Profile;
        if (!byProfile.TryGetValue(profile, out var list)) byProfile[profile] = list = new();
        list.Add(turn);
        isRunning = true;
        Raise(nameof(turns));
        try
        {
            if (!await SessionCheck.shared.AuthorizeAction()) { turn.error = "Không hỏi được lúc này."; return; }
            var a = await Answer(question, history);
            turn.answer = a.text; turn.backend = a.backend; turn.ms = a.ms;
        }
        catch (Exception e) { turn.error = $"Không trả lời được: {e.Message}"; }
        finally
        {
            isRunning = false;
            Raise(nameof(turns));
        }
    }

    /// Chọn dữ liệu liên quan của game đang chọn rồi hỏi model. Dùng chung cho app và trang web.
    public static async Task<TranslationRouter.StoryAnswer> Answer(string question, IReadOnlyList<StoryQA.Turn> history)
    {
        var store = HistoryStore.shared;
        var profile = Profile;
        var material = StoryQA.Gather(question, store.story, store.storyParts, history, terms => store.SearchEntries(profile, terms, 300));
        try
        {
            var a = await Pipeline.shared.router.AskStory(material);
            Log.Info($"Hỏi đáp [{a.backend}] {a.ms}ms, gửi {a.inputChars} ký tự (~{a.inputChars * 2 / 7} token), trả {a.text.Length} ký tự: " +
                     (question.Length > 80 ? question[..80] : question));
            return a;
        }
        catch (Exception e)
        {
            Log.Error($"Hỏi đáp lỗi: {e.Message}");
            throw;
        }
    }
}
