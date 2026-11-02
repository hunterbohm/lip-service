/// Frequent English words, and the words that label buttons and lists in apps. A word here is never taken as a name
/// from the screen or learned from a fix, since boosting it would turn the everyday word into the name.
public enum CommonWords {
    /// Also true for a plain inflection of a listed word, such as "following", "numbers" or "signed".
    public static func contains(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if words.contains(lowered) { return true }
        for suffix in ["'s", "’s", "s", "es", "ed", "d", "ing", "ly"] where lowered.hasSuffix(suffix) && lowered.count > suffix.count + 2 {
            let base = String(lowered.dropLast(suffix.count))
            if words.contains(base) || words.contains(base + "e") { return true }
        }
        return false
    }

    static let words: Set<String> = Set(list.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let list = """
        a about above across act action actually add added after again against age ago agree ahead air all allow almost
        alone along already also although always am among amount an and angry animal another answer any anyone anything
        anyway anywhere apart app apps april are area aren't arm around arrive art article as ask asked at attach august
        available away awesome baby back bad bag ball bank bar base basic be beautiful became because become bed been
        before began begin behind being believe below best better between big bill bit black blue board body book both
        bottom box boy break bring brought brown build building built business busy but buy by call called came can can't
        cancel car card care carry case cat catch cause center certain chance change chat check child children choose
        city class clean clear close closed cold color come comment comments common company complete contact content
        continue copy correct cost could couldn't count country course cover create cut dad dark data date day days dead
        deal dear december decide deep delete design detail details did didn't die different dinner direct do does
        doesn't dog doing don't done door down download draft drafts draw dream drink drive drop during each early earth
        easy eat edit either else email emails end enough enter even evening event ever every everyone everything exactly
        example except expect eye eyes face fact fall family far fast father favorite february feel feet felt few field
        file files fill final finally find fine finish fire first fish five fix floor fly follow food foot for form format
        forward found four free friday friend friends from front full fun funny game gave get gets getting girl give given
        glad go goes going gone good got great green ground group grow guess guy guys had half hand hands happen happy
        hard has hasn't have haven't having he he's head hear heard heart heavy hello help her here hers hey hi high
        him his history hold home hope hot hour hours house how however huge human hundred i i'd i'll i'm i've idea if
        important in inbox include including info information inside instead interest into is isn't issue it it's item
        items its itself january job join july june just keep kept kid kids kind knew know known land language large last
        late later laugh lead learn least leave left less let let's letter life light like likely line link list listen
        little live load local long look looked looking lose lost lot lots love low made mail main make makes making man
        many march mark matter may maybe me mean meet meeting member mention mentions menu message messages met middle
        might mind mine minute minutes miss moment monday money month months more morning most mother move movie much
        music must my myself name near need needs never new news next nice night nine no none nor normal not note notes
        nothing notice november now number of off offer office often oh ok okay old on once one only open or order other
        others our ours out outside over own page paper part party pass past pay people per perfect perhaps person phone
        pick picture piece place plan play please plus point post power present pretty price print probably problem
        profile project pull push put question quick quickly quite rather read reading ready real really reason receive
        recent red remember remove reply report rest result right river road room round run said same saturday save saw
        say says school screen search second section see seem seen send sent september set settings seven several shall
        share she she's ship short should shouldn't show side sign simple since sir sit six size sleep slow small so some
        someone something sometimes song soon sorry sound space speak special spend stand star start state stay step
        still stop story street strong student study stuff such sunday sure system table take taken talk tax team tell
        ten test text than thank thanks that that's the their theirs them then there there's these they they're thing
        things think third this those though thought thousand thread threads three through thursday till time times
        title to today together told tomorrow tonight too took top total toward town track tree tried trip true try
        trying tuesday turn two type under understand unless unread until up update upon us use used user using usual
        very video view visit voice wait walk wall want wanted war was wasn't watch water way we we'll we're we've
        wednesday week weekend weeks welcome well went were weren't what what's when where whether which while white
        who whole whom whose why wide will window wish with within without woman women won't wonder word words work
        working world worry would wouldn't write wrong yeah year years yes yesterday yet you you'd you'll you're you've
        young your yours yourself
        absolutely account activity advanced align appearance archive attachment audio basically bcc bold browser bug
        bullet busy calendar camera canvas cc channel channels chats cheers client code commit contacts contract cool
        customer dashboard definitely deploy desktop document documents downloads emoji favorites feature filter flag
        folder font general gif haha honestly hopefully huddle image insert invoice italic junk justify label labels
        launch lol login logout merge microphone mode mute nope notification notifications offline omg online password
        paste photo photos pin pinned poll preferences preview privacy recents record recording redo regards release
        reminder replace review schedule security select seriously shared sidebar sincerely sort spam speaker standup
        starred status sticker style subject support tab tag tags task tasks terminal theme todo toolbar totally trash
        underline undo untitled username version workflow yep yup btw fyi thx pls
        """
}
